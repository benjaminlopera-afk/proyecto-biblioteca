# Informe S14 · Esquema PostgreSQL y carga de datos desde CSV

## Autores:
Juan Pablo Lozano Restrepo - 202521505
Sebastián Martínez cabrera - 2519817
Benjamin Lopera - 2515144
Jhonny Alexander Moreno - 2522112

Avance del **Hito 2** (entrega final en S16): esquema como script de arranque, carga de libros y lectores desde los CSV semilla del curso (incluidos los archivos con errores) y CSV propio con prueba de la última línea de defensa.

| Campo | Detalle |
|---|---|
| Repositorio | `proyecto-biblioteca` |
| Rama principal | `main` (3 PRs fusionados) |
| Contenedor PostgreSQL | `postgres:16`, BD `curso` |
| Fecha de verificación | 27/10/2026 |

---

## 0. Resumen de ejecucion

1. **`postgres/init/01_esquema.sql`** (esquema de arranque) más los dos scripts de carga **`S14-carga-libros.sql`** y **`S14-carga-lectores.sql`**.
2. Las dos tablas del paso 3 de la mecánica: **mapeo CSV → esquema** y **criterios por tipo de error**.
3. **CSV propio** de libros y de lectores, con 5 filas válidas inéditas y 3 errores nuevos cada uno.
4. **Salidas de `psql`** de las cargas requeridas (libros limpio, libros con errores, lectores con errores y CSV propio) más la **respuesta a la prueba de la última línea de defensa**.

Todos los resultados de este informe fueron **verificados ejecutando los scripts del repositorio** en un PostgreSQL 16 levantado desde cero con `docker` (base vacía, `init/` corriendo solo), usando los CSV que están en `postgres/scripts/datos/`.

Resultados principales:

- Carga limpia de libros: **32 libros, 94 ejemplares, 0 rechazados**.
- Carga con errores de libros: **8 filas rechazadas** con motivo legible en la bitácora; 0 contaminan la base.
- Carga limpia de lectores: **20 usuarios, 0 rechazados**.
- Carga con errores de lectores: **6 filas rechazadas** con motivo legible.
- CSV propio (libros y lectores): **5 válidas cargadas + 3 errores nuevos atrapados** en cada uno.
- **Idempotencia**: repetir la carga limpia no duplica nada (las 32 filas salen rechazadas por «isbn ya existe en el catálogo»).
- **Última línea de defensa**: al desactivar a propósito una regla del `CASE`, la fila mala chocó contra el `CHECK` del esquema y la transacción hizo **ROLLBACK** completo (ni las válidas ni la bitácora se guardaron), demostrando que el esquema es la última línea de defensa y no el validador.

---

## 1. Entregable 1 · Esquema como script de arranque y scripts de carga

### 1.1 `postgres/init/01_esquema.sql` — el esquema como script de arranque

El esquema del grupo (`biblioteca-v2.sql` de la S11) se movió a **`postgres/init/01_esquema.sql`** para que el entrypoint de Docker lo ejecute **solo, una vez, cuando la base se crea vacía** (la carpeta `init/` está montada en `/docker-entrypoint-initdb.d` en el `docker-compose.yml`).

Ajuste en dif: base `e275984` → `HEAD`, +23 líneas:

| # | Cambio | Motivo |
|---|---|---|
| 1 | `CREATE EXTENSION IF NOT EXISTS pgcrypto;` | Disponible para guardar la contraseña inicial de los lectores con hash  |
| 2 | `UNIQUE` en `CATEGORIA.nombre` | La carga se puede repetir sin duplicar categorías |
| 3 | `UNIQUE` en `AUTOR.nombre` | La carga se puede repetir sin duplicar autores |
| 4 | `CHECK chk_libro_isbn` → `"ISBN" ~ '^[0-9]{13}$'` | Última línea de defensa para el ISBN |
| 5 | `CHECK chk_libro_titulo` → `btrim("titulo") <> ''` | Última línea de defensa para el título |
| 6 | `CHECK chk_libro_ano` → `"ano_publicacion" BETWEEN 1450 AND 2100` | Última línea de defensa para el año |

Estas restricciones son la **última línea de defensa**, no el validador de la carga: si una fila llega a chocar con un `CHECK`, la validación del `CASE` ya falló.

**Verificación (base vacía):** se levantó el servicio `postgres:16` con la carpeta `postgres/init/` montada y una base recién creada; sin ejecutar nada a mano, `\dt` muestra las 8 tablas:

```
List of relations
 Schema |    Name     | Type  | Owner
--------+-------------+-------+-------
 public | AUTOR       | table | curso
 public | CATEGORIA   | table | curso
 public | EJEMPLAR    | table | curso
 public | LIBRO       | table | curso
 public | LIBRO_AUTOR | table | curso
 public | PRESTAMO    | table | curso
 public | ROL         | table | curso
 public | USUARIO     | table | curso
(8 rows)
```

### 1.2 `S14-carga-libros.sql` y `S14-carga-lectores.sql` — scripts de carga

Ambos scripts implementan el patrón del laboratorio dentro de una **transacción atómica** (`BEGIN … COMMIT`):

```
archivo .csv
   │  COPY con FORMAT text (1 fila = 1 línea; ninguna línea se pierde, aunque sea rara)
   ▼
tabla de paso stg_* (todo texto, sin restricciones) ─► UPDATE … SET motivo = CASE (validar)
   │                            │
   │ motivo IS NULL             │ motivo IS NOT NULL
   ▼                            ▼
tablas finales                  bitácora rechazo_carga
(propio esquema)                (persiste entre cargas)
```

| Fase | `carga-libros.sql` | `carga-lectores.sql` |
|---|---|---|
| **Lectura** | `COPY carga.stg_linea (linea) FROM :'archivo' WITH (FORMAT text)`; se elimina la línea 1 (encabezado) y las líneas en blanco | Igual, con `stg_linea` |
| **Partición** | Cada línea se parte en 6 campos con `split_part`, `trim` y conteo de `num_campos` | Igual con 5 campos; además el correo se normaliza con **`lower()`** |
| **Validación** | `UPDATE carga.stg_libro SET motivo = CASE …` (primera regla que falla da el motivo) | `UPDATE stg_lector SET motivo = CASE …` |
| **Duplicados en el archivo** | ISBN repetido → se conserva la primera aparición válida | Documento o correo repetido → se conserva la primera |
| **Carga a tablas finales** | 5 `INSERT … SELECT`: `CATEGORIA`, `AUTOR`, `LIBRO`, `LIBRO_AUTOR` y `EJEMPLAR` | 1 `INSERT`: `USUARIO` (con rol `'LECTOR'`, nombre concatenado y contraseña provisional) |
| **Bitácora** | `INSERT INTO carga.rechazo_carga (archivo, linea, contenido, motivo)` | `INSERT INTO rechazo_carga (archivo, linea, contenido, motivo)` |

Decisiones clave del diseño:

- **Descomposición relacional**: el CSV de libros (1 fila) se reparte en 5 tablas del esquema. La categoría y el autor se dan de alta solo si no existen (`UNIQUE` + `NOT EXISTS`), y sus id se continúan del máximo existente (`CAT-###`, `AUT-####`) con `lpad`. `ejemplares_disponibles` se convierte en *n* filas en `EJEMPLAR` con `generate_series(1, n)` y estado `'disponible'`.
- **Normalizaciones**: `trim` en todos los campos, `lower` en correos, y el `'LECTOR'` se asegura en `ROL` con `ON CONFLICT DO NOTHING`.
- **Contraseña provisional**: los CSV no traen contraseña; se asigna el **documento** como clave inicial para cumplir el `NOT NULL`. Pendiente para el Hito 5: hash con `pgcrypto`.
- **Reorden seguro de reglas**: los cast `::integer` van **después** de la regla que comprueba que el texto son dígitos, para que un valor no numérico nunca llegue a convertirse.
- **Idempotencia**: `CREATE TABLE IF NOT EXISTS` + `TRUNCATE` al inicio + comprobación de duplicados con `EXISTS` contra las tablas finales ⇒ repetir una carga no duplica datos.

## 2. Entregable 2 · Mapeo CSV → esquema y criterios por tipo de error

### 2.1 Mapeo `libros_semilla*.csv` → esquema

| Columna del CSV | Tabla.columna destino | Transformación | Regla de validación (motivo) |
|---|---|---|---|
| `isbn` | `LIBRO.ISBN` | `trim` | vacío → «isbn vacío» · regex `^[0-9]{13}$` → «isbn no tiene 13 dígitos» · `EXISTS` en `LIBRO` → «isbn ya existe en el catálogo» · repetido en el archivo → «isbn repetido en el archivo» |
| `titulo` | `LIBRO.titulo` | `trim` | vacío → «título vacío» |
| `autor` | `AUTOR.nombre` **y** `LIBRO_AUTOR.id_autor` | `trim`; alta con id `AUT-####` si no existe (`UNIQUE` en `nombre`) | vacío → «autor vacío» |
| `categoria` | `CATEGORIA.nombre` **y** `LIBRO.id_categoria` | `trim`; alta con id `CAT-###` si no existe (`UNIQUE` en `nombre`) | vacío → «categoría vacía» |
| `anio_publicacion` | `LIBRO.ano_publicacion` | `trim` + `::integer` | regex `^[0-9]{1,4}$` → «año no numérico» · `NOT BETWEEN 1450 AND año actual` → «año fuera de rango» |
| `ejemplares_disponibles` | `EJEMPLAR` (n filas) | `generate_series(1,n)` → `num_ejemplar`; `estado = 'disponible'` | regex `^-?[0-9]{1,4}$` → «ejemplares no numérico» · `< 0` → «ejemplares negativo» |
| *(columna de más)* | — | `num_campos` | `num_campos <> 6` → «tiene N columnas, se esperaban 6» |

### 2.2 Mapeo `lectores_semilla*.csv` → esquema

| Columna del CSV | Tabla.columna destino | Transformación | Regla de validación (motivo) |
|---|---|---|---|
| `documento` | `USUARIO.id_usuario` **y** `USUARIO.contrasena` (clave provisional = documento) | `trim` | vacío → «documento vacío» · regex `^[0-9]{6,15}$` → «documento no numérico o de longitud inválida» · `EXISTS` en `USUARIO` → «documento ya existe» |
| `nombres` | `USUARIO.nombre` (concatenada con apellidos) | `trim` | vacío → «nombres vacío» |
| `apellidos` | `USUARIO.nombre` (`nombres \|\| ' ' \|\| apellidos`) | `trim` | vacío → «apellidos vacío» |
| `correo` | `USUARIO.correo` | `lower(trim(...))` | vacío → «correo vacío» · regex `^[^@ ]+@[^@ ]+\.[^@ ]+$` → «correo mal formado» · `EXISTS` en `USUARIO` → «correo ya registrado por otro usuario» |
| `telefono` | `USUARIO.telefono` | `trim` | regex `^[0-9]{7,15}$` → «teléfono no numérico o de longitud inválida» |
| `id_rol` | `USUARIO.id_rol` | fijo `'LECTOR'`; el rol se asegura en `ROL` con `ON CONFLICT DO NOTHING` | — |
| *(duplicado interno)* | — | `EXISTS` sobre `stg_lector` | mismo documento o correo en línea anterior → «documento o correo repetido en el archivo» |
| *(columna de más)* | — | `num_campos` | `num_campos <> 5` → «tiene N columnas, se esperaban 5» |

### 2.3 Criterios por tipo de error (14 errores de los CSV semilla + 6 propios)

Se usó una política única: **rechazar todo lo que no se puede corregir con una normalización mecánica** (`trim`, `lower`) y registrar el motivo legible en la bitácora. No hay casos de «actualizar»: la carga es de alta y ante ambigüedad no se adivinan datos.

**Libros — `libros_semilla_con_errores.csv` (8 filas):**

| Línea | Problema | Motivo en bitácora | Decisión | Por qué |
|---|---|---|---|---|
| 2 | ISBN ya existente en el catálogo | isbn ya existe en el catálogo | Rechazar | El libro ya está; sin más información no se sabe si es una actualización; se evita duplicar |
| 3 | Título vacío | título vacío | Rechazar | Dato obligatorio e irrecuperable |
| 4 | Año «dos» (no numérico) | año no numérico | Rechazar | No se puede adivinar el valor |
| 5 | Año «MCMXLIX» (romano) | año no numérico | Rechazar | Se exige año en cifras arábigas (criterio consistente con la regex `[0-9]`) |
| 6 | 7 columnas en vez de 6 | tiene 7 columnas, se esperaban 6 | Rechazar | Estructura corrupta: no se sabe cuál es el dato sobrante |
| 7 | Autor vacío | autor vacío | Rechazar | Irrecuperable y relevante para la ficha |
| 8 | ISBN vacío | isbn vacío | Rechazar | Clave del catálogo sin valor |
| 9 | Ejemplares negativos (−3) | ejemplares negativo | Rechazar | Una cantidad de copias negativa no tiene sentido de negocio |

**Lectores — `lectores_semilla_con_errores.csv` (6 filas):**

| Línea | Problema | Motivo en bitácora | Decisión | Por qué |
|---|---|---|---|---|
| 2 | Documento ya existente (vs. carga limpia) | documento ya existe | Rechazar | El usuario ya está registrado; la carga es de alta, no de actualización |
| 3 | Correo vacío | correo vacío | Rechazar | Irrecuperable |
| 4 | Correo mal formado (sin @/. válidos) | correo mal formado | Rechazar | No cumple el patrón mínimo `a@b.c` |
| 5 | Teléfono alfanumérico («tres-cero-cero») | teléfono no numérico o de longitud inválida | Rechazar | Solo se aceptan 7–15 dígitos |
| 6 | Documento vacío | documento vacío | Rechazar | Identificador principal sin valor |
| 7 | Nombres vacíos | nombres vacío | Rechazar | Irrecuperable |

**CSV propio (6 errores nuevos, distintos de los del curso):**

| Archivo | Línea | Problema | Motivo en bitácora | Decisión | Por qué |
|---|---|---|---|---|---|
| `libros_propio.csv` | 7 | Mismo ISBN dos veces en el archivo | isbn repetido en el archivo | Rechazar (se conserva la 1.ª aparición) | El archivo no puede dar de alta dos veces el mismo libro |
| `libros_propio.csv` | 8 | Año futuro (2030) | año fuera de rango | Rechazar | El rango admitido es 1450 → año actual |
| `libros_propio.csv` | 9 | Archivo guardado con `;` | tiene 1 columnas, se esperaban 6 | Rechazar | Separador inválido: la fila no se puede partir |
| `lectores_propio.csv` | 7 | Correo repetido con otra mayúscula (`ANDRES.GOMEZ@TEST.COM`) | documento o correo repetido en el archivo | Rechazar | `lower()` normaliza antes de comparar; se detecta como duplicado de una línea anterior del mismo archivo |
| `lectores_propio.csv` | 8 | Teléfono alfanumérico (`300789012a`) | teléfono no numérico o de longitud inválida | Rechazar | Solo se aceptan 7–15 dígitos |
| `lectores_propio.csv` | 9 | Archivo guardado con `;` | tiene 1 columnas, se esperaban 5 | Rechazar | Separador inválido: la fila no se puede partir |

## 3. Entregable 3 · CSV propio

Se crearon dos archivos en `postgres/scripts/datos/`, cada uno con **5 filas válidas inéditas** (no están en los CSV semilla) y **3 errores que no aparecen en los archivos del curso**.

### 3.1 `libros_propio.csv`

```
isbn,titulo,autor,categoria,anio_publicacion,ejemplares_disponibles
9788420471839,Cien anos de soledad,Gabriel Garcia Marquez,Novela,1967,4   ← válida
9788437604947,Pedro Paramo,Juan Rulfo,Novela,1955,3                       ← válida
9788497592208,La ciudad y los perros,Mario Vargas Llosa,Novela,1962,5     ← válida
9788437621494,Rayuela,Julio Cortazar,Novela,1963,2                        ← válida
9788466332095,El amor en los tiempos del colera,Gabriel Garcia Marquez,Novela,1985,3  ← válida
9788420471839,Cien anos de soledad Duplicado,Gabriel Garcia Marquez,Novela,1967,2     ← ERROR 1
9789999999999,Viaje al Futuro,Autor Ejemplo,Ciencia Ficcion,2030,2                     ← ERROR 2
9788888888888;Libro Separado Por Punto Y Coma;Autor Raro;Ensayo;2020;3                 ← ERROR 3
```

| # | Error nuevo probado | Cómo se define en el archivo | Motivo esperado en la bitácora |
|---|---|---|---|
| 1 | **ISBN duplicado dentro del mismo archivo** | `9788420471839` repite en la línea 7 | isbn repetido en el archivo |
| 2 | **Año en el futuro** | `2030` (año actual = 2026) | año fuera de rango |
| 3 | **Archivo guardado con `;`** | fila con separador punto y coma (1 sola «columna») | tiene 1 columnas, se esperaban 6 |

### 3.2 `lectores_propio.csv`

```
documento,nombres,apellidos,correo,telefono
1001002001,Andres,Gomez,andres.gomez@test.com,3001234567        ← válida
1001002002,Beatriz,Lopez,beatriz.lopez@test.com,3002345678      ← válida
1001002003,Camilo,Ruiz,camilo.ruiz@test.com,3003456789          ← válida
1001002004,Daniela,Morales,daniela.morales@test.com,3004567890  ← válida
1001002005,Esteban,Rios,esteban.rios@test.com,3005678901        ← válida
1001002006,Fernanda,Perez,ANDRES.GOMEZ@TEST.COM,3006789012      ← ERROR 1
1001002007,Gabriel,Silva,gabriel.silva@test.com,300789012a      ← ERROR 2
1001002008;Hugo;Vargas;hugo.vargas@test.com;3008901234          ← ERROR 3
```

| # | Error nuevo probado | Cómo se define en el archivo | Motivo esperado en la bitácora |
|---|---|---|---|
| 1 | **Correo repetido con otra mayúscula** | `ANDRES.GOMEZ@TEST.COM` vs `andres.gomez@test.com` (línea 2) | documento o correo repetido en el archivo |
| 2 | **Teléfono con caracteres alfanuméricos** | `300789012a` | teléfono no numérico o de longitud inválida |
| 3 | **Archivo guardado con `;`** | fila con separador punto y coma | tiene 1 columnas, se esperaban 5 |

> Nota de diseño: los nombres del CSV propio se escribieron **sin tildes** a propósito (p. ej. «Julio Cortazar») para que se traten como autores/categorías nuevos y no colisionen con los autores con tilde de la semilla («Julio Cortázar»). El `UNIQUE` de `AUTOR.nombre`/`CATEGORIA.nombre` y el `EXISTS` de validación distinguen entre ambas grafías.

## 4. Entregable 4 · Salidas de `psql` de las cargas

Comandos usados (el archivo se cambia con `-v archivo=…`; por defecto es el CSV limpio):

```bash
docker compose exec postgres psql -U curso -d curso -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso \
  -v archivo=/scripts/datos/libros_semilla_con_errores.csv -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/S14-carga-lectores.sql
# … y con -v archivo=…/lectores_semilla_con_errores.csv, …/libros_propio.csv, …/lectores_propio.csv
```

### 4.1 Carga limpia de libros — `libros_semilla.csv` → 32 libros, 94 ejemplares, 0 rechazados

```
BEGIN
TRUNCATE TABLE
TRUNCATE TABLE
COPY 33
DELETE 1
DELETE 0
INSERT 0 32
UPDATE 32
UPDATE 0
INSERT 0 9      -- 9 categorías nuevas
INSERT 0 29     -- 29 autores nuevos
INSERT 0 32     -- 32 libros
INSERT 0 32     -- 32 relaciones libro-autor
INSERT 0 94     -- 94 ejemplares (generate_series)
INSERT 0 0      -- bitácora: 0 rechazos
COMMIT
 cargadas | rechazadas
----------+------------
       32 |          0
(1 row)

 linea | motivo | contenido
-------+--------+-----------
(0 rows)
```

### 4.2 Carga de libros con errores — `libros_semilla_con_errores.csv` → 8 rechazadas, 0 válidas

*(en la transacción las 8 filas se marcan con motivo y ninguna llega a las tablas finales)*

```
 cargadas | rechazadas
----------+------------
        0 |          8
(1 row)

 linea |              motivo              |                                          contenido
-------+----------------------------------+--------------------------------------------------------------------------------------------
     2 | isbn ya existe en el catálogo    | 9780000000001,Cien años de soledad (edición duplicada),Gabriel García Márquez,Novela,1967,2
     3 | título vacío                     | 9780000000033,,Julio Cortázar,Novela,1963,3
     4 | año no numérico                  | 9780000000034,Relato sin ejemplares numéricos,Autor de Prueba,Novela,dos,3
     5 | año no numérico                  | 9780000000035,Relato con año inválido,Autor de Prueba,Novela,MCMXLIX,2
     6 | tiene 7 columnas, se esperaban 6 | 9780000000036,Relato con columna de más,Autor de Prueba,Novela,1999,2,columna_sobrante
     7 | autor vacío                      | 9780000000037,Relato sin autor,,Novela,2005,1
     8 | isbn vacío                       | ,Relato sin ISBN,Autor de Prueba,Novela,2010,1
     9 | ejemplares negativo              | 9780000000038,Relato con ejemplares negativos,Autor de Prueba,Novela,2015,-3
(8 rows)
```

Los **8 errores del curso quedan atrapados** en la bitácora, cada uno con motivo legible, y las filas válidas del mismo archivo (ninguna en este caso) pasarían. Al consultar la bitácora:

```
SELECT archivo, linea, motivo FROM carga.rechazo_carga ORDER BY id;
```

### 4.3 Carga limpia de lectores — `lectores_semilla.csv` → 20 usuarios, 0 rechazados

```
 cargadas | rechazadas
----------+------------
       20 |          0
(1 row)
```

(previo en la transacción: se asegura el rol `LECTOR` con `INSERT 0 1` y se insertan los 20 usuarios con nombre concatenado, correo en minúsculas y documento como contraseña provisional.)

### 4.4 Carga de lectores con errores — `lectores_semilla_con_errores.csv` → 6 rechazadas

```
 cargadas | rechazadas
----------+------------
        0 |          6
(1 row)

 linea |                   motivo                    |                                        contenido
-------+---------------------------------------------+-----------------------------------------------------------------------------------------
     2 | documento ya existe                         | 1000000001,Mariana,Gómez Rojas (duplicado),mariana.gomez@correo-ejemplo.edu.co,3001000001
     3 | correo vacío                                | 1000000021,Carlos,Peña Londoño,,3001000021
     4 | correo mal formado                          | 1000000022,Diana,Salgado Cuervo,diana.salgado-arroba-correo-ejemplo.edu.co,3001000022
     5 | teléfono no numérico o de longitud inválida | 1000000023,Jorge,Restrepo Vélez,jorge.restrepo@correo-ejemplo.edu.co,tres-cero-cero
     6 | documento vacío                             | ,Sin Documento,Prueba Prueba,sin.documento@correo-ejemplo.edu.co,3001000024
     7 | nombres vacío                               | 1000000025,,Sin Nombre,sin.nombre@correo-ejemplo.edu.co,3001000025
(6 rows)
```

### 4.5 Carga del CSV propio — libros y lectores → 5 válidas + 3 rechazos nuevos en cada uno

**`libros_propio.csv`:**

```
 cargadas | rechazadas
----------+------------
        5 |          3
(1 row)

 linea |              motivo              |                                    contenido
-------+----------------------------------+---------------------------------------------------------------------------
     7 | isbn repetido en el archivo      | 9788420471839,Cien anos de soledad Duplicado,Gabriel Garcia Marquez,Novela,1967,2
     8 | año fuera de rango               | 9789999999999,Viaje al Futuro,Autor Ejemplo,Ciencia Ficcion,2030,2
     9 | tiene 1 columnas, se esperaban 6 | 9788888888888;Libro Separado Por Punto Y Coma;Autor Raro;Ensayo;2020;3
(3 rows)
```

**`lectores_propio.csv`:**

```
 cargadas | rechazadas
----------+------------
        5 |          3
(1 row)

 linea |                   motivo                    |                          contenido
-------+---------------------------------------------+-----------------------------------------------------------
     7 | documento o correo repetido en el archivo   | 1001002006,Fernanda,Perez,ANDRES.GOMEZ@TEST.COM,3006789012
     8 | teléfono no numérico o de longitud inválida | 1001002007,Gabriel,Silva,gabriel.silva@test.com,300789012a
     9 | tiene 1 columnas, se esperaban 5            | 1001002008;Hugo;Vargas;hugo.vargas@test.com;3008901234
(3 rows)
```

### 4.6 Repetibilidad / idempotencia — volver a cargar el archivo limpio de libros

Se vuelve a correr `carga-libros.sql` con `libros_semilla.csv` **sin borrar nada**. Resultado: 0 cargadas, 32 rechazadas con motivo «isbn ya existe en el catálogo». **La carga se puede repetir sin duplicar datos**, porque la validación con `EXISTS` contra `LIBRO` atrapa lo ya cargado y la bitácora conserva el motivo:

```
 cargadas | rechazadas
----------+------------
        0 |         32
(1 row)

 linea |            motivo             |                                contenido
-------+-------------------------------+---------------------------------------------------------------------------
     2 | isbn ya existe en el catálogo | 9780000000001,Cien años de soledad,Gabriel García Márquez,Novela,1967,4
     3 | isbn ya existe en el catálogo | 9780000000002,El amor en los tiempos del cólera,Gabriel García Márquez,Novela,1985,3
   …  | …                             | … (32 filas en total)
```

### 4.7 Prueba de la última línea de defensa (paso 5 de la mecánica)

**Procedimiento:** en una **copia temporal** del script de carga de libros se comentó a propósito la regla de validación `WHEN titulo = '' THEN 'título vacío'` del `CASE`, y se volvió a cargar `libros_semilla_con_errores.csv`. Al quedar sin regla que la detenga, la fila 3 (título vacío) pasó las etapas de staging y llegó al `INSERT INTO LIBRO`.

**Qué pasó — falló el `INSERT` contra el `CHECK` del esquema y se abortó toda la transacción:**

```
psql:exp-carga-libros.sql:117: ERROR:  new row for relation "LIBRO" violates check constraint "chk_libro_titulo"
DETAIL:  Failing row contains (9780000000033, CAT-007, , null, 1963).
```

**Respuestas a las preguntas del paso 5:**

- **¿Qué pasa con las demás filas de esa carga?** Como todo ocurre dentro de `BEGIN … COMMIT` y el `INSERT` falló, psql detiene el script y la transacción hace ROLLBACK: las demás filas (válidas o rechazadas por otras reglas) no se guardan. Es el comportamiento **todo o nad** que se evita con la validación previa.
- **¿Y con la bitácora?** También se revierte: los `INSERT` a `carga.rechazo_carga` de esa corrida quedan **anulados**, porque la bitácora se escribe en la misma transacción. Verificado con conteos antes/después (las tablas finales y la bitácora quedaron idénticas a como estaban).
- **Conclusión:** confirma la idea central del laboratorio: las restricciones del esquema son la última línea de defensa, no el validador de la carga. Si una fila llega a chocar con un `CHECK`, la validación ya falló y la consecuencia es dramática (pierde toda la corrida, no solo la fila mala). Al terminar la prueba se restauró la regla en el script del repositorio.

### 4.8 Estado final de las tablas (después de todas las cargas del entregable)

Consulta de verificación con `SELECT count(*)`:

```
        tabla         | filas
----------------------+-------
 AUTOR                |    32   (29 semilla + 3 del CSV propio, grafía sin tilde)
 CATEGORIA            |     9   (9 de la semilla; el propio no agrega: su fila nueva era rechazada)
 EJEMPLAR             |   111   (94 semilla + 17 del propio)
 LIBRO                |    37   (32 semilla + 5 propio)
 LIBRO_AUTOR          |    37
 USUARIO              |    25   (20 semilla + 5 propio)
 ROL                  |     1   ('LECTOR', asegurado con ON CONFLICT)
 carga.rechazo_carga  |    43   (8 semilla-errores + 3 propio + 32 rechazos de la prueba de idempotencia)
 public.rechazo_carga |     9   (6 semilla-errores + 3 propio, bitácora de lectores)
```

> Los 43/9 registros de la bitácora demuestran que **las válidas entran y las malas se registran sin abortar la carga**, y que las bitácoras persisten entre corridas para poder depurar y recargar.

## 5. Detalle de los cambios hechos por pull request

Los cambios están en la rama `main`, entregados en 3 PRs desde ramas `feature/`:

| PR | Rama | Commit de merge | Mensaje | Archivos |
|---|---|---|---|---|
| #1 | `feature/02-carga-libros` | `ea6cb13` | `feat: implementa carga de libros` | `postgres/init/01_esquema.sql` (+23), `postgres/scripts/S14-carga-libros.sql` (+215/−71) |
| #2 | `feature/03-carga-lectores` | `4462750` | `feat(lectores): script de carga masiva de usuarios y gestión de roles` | `postgres/scripts/S14-carga-lectores.sql` (+57/−26) |
| #3 | `feature/04-csv-propio` | `c6b4d42` | `test(defensa): validación de ETLs mediante CSVs propios y control de reglas` | `postgres/scripts/S14-carga-libros.sql` (cosmético), `postgres/scripts/datos/libros_propio.csv` (nuevo), `postgres/scripts/datos/lectores_propio.csv` (nuevo) |

### PR #1 — Carga masiva de libros (patrón staging → validación → carga → bitácora)

**Descripción:** implementación de `postgres/scripts/S14-carga-libros.sql` adaptado al esquema `01_esquema.sql` mediante el patrón Staging → Validación → Carga final → Bitácora dentro de una transacción atómica.

Cambios principales:

- **Descomposición relacional**: mapea las 6 columnas del CSV hacia 5 tablas del proyecto: `CATEGORIA`, `AUTOR`, `LIBRO`, `LIBRO_AUTOR` y `EJEMPLAR`.
- **Generación de IDs y ejemplares**: secuencias automáticas `CAT-###` y `AUT-####` que continúan desde el máximo existente (permite repetir la carga), y conversión de `ejemplares_disponibles` en *n* filas independientes con `generate_series`.
- **Reglas de validación en el `CASE`**: regex para ISBN (13 dígitos), año en rango 1450–año actual, ejemplares no negativos, prevención de campos vacíos y control de duplicados (contra la tabla y dentro del archivo).
- **Manejo de errores**: registro en `carga.rechazo_carga` sin abortar la ejecución.
- **Ajustes al esquema** (`01_esquema.sql`): `pgcrypto`, `UNIQUE` en `CATEGORIA.nombre` y `AUTOR.nombre`, y `CHECK`s en `LIBRO` (ISBN, título, año) como última línea de defensa.

Pruebas realizadas y verificadas en este informe:

- Carga limpia (`libros_semilla.csv`): **32 libros y 94 ejemplares** insertados (0 rechazados).
- Carga con errores (`libros_semilla_con_errores.csv`): **8 filas** invalidadas y capturadas en la bitácora.
- **Idempotencia**: la reejecución rechaza las filas existentes por duplicado de ISBN sin contaminar la base.

### PR #2 — Carga masiva de lectores (`USUARIO` y `ROL`)

**Descripción:** implementación de `postgres/scripts/S14-carga-lectores.sql` adaptado a `"USUARIO"` y `"ROL"` del esquema, con el mismo patrón dentro de una transacción atómica.

Cambios principales:

- **Mapeo relacional y roles**: integración con la tabla `USUARIO`, garantizando la existencia del rol `'LECTOR'` en `ROL` (`ON CONFLICT DO NOTHING`) e insertando el nombre completo concatenado (`nombres || ' ' || apellidos`).
- **Asignación de credenciales**: el documento se usa como contraseña provisional en `contrasena` para satisfacer el `NOT NULL`.
- **Normalización y validaciones**: correos a minúsculas (`lower`), regex para documento (`^[0-9]{6,15}$`), correo (`^[^@ ]+@[^@ ]+\.[^@ ]+$`) y teléfono (`^[0-9]{7,15}$`), y control de duplicados contra la base y dentro del mismo archivo (documento o correo).
- **Manejo de errores**: registro en la bitácora `rechazo_carga` sin abortar la transacción.

Pruebas realizadas y verificadas en este informe:

- Carga limpia (`lectores_semilla.csv`): **20 usuarios** insertados (0 rechazados).
- Carga con errores (`lectores_semilla_con_errores.csv`): **6 filas** invalidadas en la bitácora (documento o correo vacíos/mal formados, teléfonos inválidos y duplicados).

### PR #3 — CSV propio y prueba de la última línea de defensa

**Descripción:** implementación y validación del escenario de defensa de los ETL de libros y lectores con conjuntos de datos personalizados.

Cambios principales:

- **CSVs propios**: `postgres/scripts/datos/libros_propio.csv` y `lectores_propio.csv`, cada uno con **5 filas válidas inéditas** y **3 errores específicos** que no estaban en los archivos del curso.
- **Validación de reglas en staging**: captura exitosa en la bitácora de:
  - correo duplicado insensible a mayúsculas (`ANDRES.GOMEZ@TEST.COM`);
  - teléfono con caracteres alfanuméricos (`300789012a`);
  - estructura corrupta por delimitador no válido (`;`);
  - ISBN duplicado dentro del mismo archivo;
  - año de publicación fuera del rango permitido (2030).
- **Experimento de restricción CHECK**: se documentó el comportamiento transaccional al omitir la regla del `CASE` en staging; el fallo directo por el `CHECK` de la base aborta la transacción completa (ROLLBACK), revirtiendo las filas válidas y anulando el registro de rechazos, demostrando la necesidad de la capa previa de validación (ver §4.7). El cambio al script fue solo cosmético (alineación de una línea del `CASE`); la regla quedó intacta.

Pruebas realizadas y verificadas en este informe:

- Carga `lectores_propio.csv`: **5 registros** en `USUARIO` y **3 rechazos aislados** en bitácora.
- Carga `libros_propio.csv`: **5 registros** en `LIBRO` y **3 rechazos aislados** en bitácora.

## 6. Checklist

| Criterio | Nivel alcanzado | Evidencia en este informe |
|---|---|---|
| **Esquema como script de arranque** | **OK** — se crea completo desde `init/` con la base vacía, sin intervención | 1.1: contenedor levantado con la base vacía y `\dt` mostrando las 8 tablas; verificado además en las cargas del 4 |
| **Carga de los CSV semilla** | **OK** — carga libros y lectores en las tablas propias, y repetirla no duplica datos | 4.1 y 4.3 (32/94 y 20) y 4.6 (reejecución → 0 cargadas / 32 rechazadas) |
| **Validación y bitácora** | **OK** — atrapa los 14 errores, cada uno con motivo legible en la bitácora, y las válidas del mismo archivo entran | 2.3 (14 criterios), 4.2 (8), 4.4 (6) y 4.5 (válidas + rechazos aislados en el mismo archivo) |
| **Criterio documentado y CSV propio** | **OK** — criterios consistentes para todos los casos y CSV propio con 3 errores nuevos atrapados en cada archivo | 2.1–2.3 (tablas de mapeo y criterios) y 3 + 4.5 (6 errores nuevos atrapados) |

## 7. Cómo reproducir las cargas

Desde la raíz del repositorio, con Docker levantado:

```bash
# 1) Levantar PostgreSQL (el esquema 01_esquema.sql se ejecuta solo con la base vacía)
docker compose up -d postgres

# 2) Cargas (el archivo por defecto es el CSV limpio; otro archivo con -v archivo=…)
docker compose exec postgres psql -U curso -d curso -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_semilla_con_errores.csv -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_propio.csv -f /scripts/S14-carga-libros.sql

docker compose exec postgres psql -U curso -d curso -f /scripts/S14-carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_semilla_con_errores.csv -f /scripts/S14-carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_propio.csv -f /scripts/S14-carga-lectores.sql

# 3) Consultar la bitácora de rechazos
docker compose exec postgres psql -U curso -d curso -c "SELECT archivo, linea, motivo FROM carga.rechazo_carga ORDER BY id;"
```

> Si se cambia `postgres/init/01_esquema.sql`, hay que recrear la base con datos vacíos para que el init vuelva a correr (`docker compose down` + borrar el volumen de datos de postgres antes de `up`).







