# Informe S14 y S15 · Esquema PostgreSQL, Carga de Datos Masiva y Reportes Dinámicos

## Autores:

Juan Pablo Lozano Restrepo - 202521505
Sebastián Martínez cabrera - 2519817
Benjamin Lopera - 2515144
Jhonny Alexander Moreno - 2522112

Avance del **Hito 2** (entrega final en S16): esquema de base de datos como script de arranque, carga masiva de libros, lectores y préstamos desde los CSV semilla y personalizados (incluyendo el manejo atómico de rechazos) y generación de la suite de reportes de negocio con cálculo dinámico de mora.

| Campo | Detalle |
| --- | --- |
| Repositorio | `proyecto-biblioteca` |
| Rama principal | `main` (Integrado mediante PR #10) |
| Contenedor PostgreSQL | `postgres:16`, BD `curso` |
| Fecha de verificación | 07/11/2026 |

---

## 0. Resumen de ejecución

1. **`postgres/init/01_esquema.sql`** (esquema de arranque actualizado con extensión `pgcrypto` y usuario por defecto `'BIBLIO-001'`), junto con los scripts de carga **`S14-carga-libros.sql`**, **`S14-carga-lectores.sql`** y **`S15-carga-prestamos.sql`**.
2. Mapeos relacionales **CSV → esquema** y criterios unificados de validación para libros, usuarios y préstamos.
3. Archivos **CSV propios** (`libros_propio.csv`, `lectores_propio.csv` y `prestamos_propios.csv`), cada uno configurado con 5 filas válidas inéditas y 3 errores para validar el sistema de bitácoras.
4. **Suite de reportes SQL (`S15-reportes.sql`)** integrada para la consulta de métricas de uso y préstamos morosos calculados de forma dinámica (`fecha_pactada < CURRENT_DATE`).

Resultados principales:

* **Carga de libros limpia (`libros_semilla.csv`)**: 32 libros, 94 ejemplares, 0 rechazados.
* **Carga de lectores limpia (`lectores_semilla.csv`)**: 20 usuarios, 0 rechazados.
* **Carga de préstamos limpia (`prestamos_semilla.csv`)**: 5 préstamos activos/devueltos, 0 rechazados.
* **Carga de préstamos con errores (`prestamos_semilla_con_errores.csv`)**: 8 filas rechazadas registradas en `carga.rechazo_carga`.
* **CSV propios (Libros, Lectores y Préstamos)**: 5 filas válidas ingresadas a las tablas finales y 3 rechazos aislados derivados a la bitácora por cada archivo.
* **Idempotencia**: Reejecutar los scripts de carga no duplica información en la base de datos (las filas existentes se derivan a la bitácora con motivos de duplicidad).
* **Reportes dinámicos de mora**: La consulta evalúa la fecha del sistema (`CURRENT_DATE`), garantizando que la condición de mora y los días de retraso se proyecten en tiempo real sin depender del texto estático de la carga inicial.

---

## 1. Entregable 1 · Esquema de arranque y scripts de carga masiva

### 1.1 `postgres/init/01_esquema.sql` — Esquema como script de arranque

Se integraron ajustes en el script de inicio montado en `/docker-entrypoint-initdb.d`:

| # | Cambio | Motivo |
| --- | --- | --- |
| 1 | `CREATE EXTENSION IF NOT EXISTS pgcrypto;` | Habilita funciones criptográficas para el encriptado de contraseñas. |
| 2 | `INSERT INTO USUARIO ('BIBLIO-001', ...)` | Crea el bibliotecario por defecto requerido para satisfacer la clave foránea (`id_bibliotecario`) durante la carga de préstamos. |
| 3 | `UNIQUE` en `CATEGORIA.nombre` y `AUTOR.nombre` | Evita duplicación de catálogos durante cargas iterativas. |
| 4 | Restricciones `CHECK` en `LIBRO` y `PRESTAMO` | Actúan como última línea de defensa a nivel de motor de base de datos. |

### 1.2 `S15-carga-prestamos.sql` — Script de carga de préstamos

Aplica el patrón de procesamiento staging en una transacción atómica (`BEGIN ... COMMIT`):

```
archivo prestamos.csv
       │
       ▼
tabla temporal stg_prestamo (lectura en formato texto)
       │
       ├─► UPDATE stg_prestamo SET motivo = CASE ... (validaciones de integridad)
       │
       ├───► (motivo IS NULL)      ──► INSERT INTO biblioteca.prestamo (asignando 'BIBLIO-001')
       │
       └───► (motivo IS NOT NULL)  ──► INSERT INTO carga.rechazo_carga

```

Decisiones clave de diseño:

* **Asignación automática de bibliotecario**: Ante la falta de dicho campo en el CSV de préstamos, el script asigna automáticamente el identificador `'BIBLIO-001'`.
* **Integridad referencial cruzada**: Verifica mediante subconsultas `EXISTS` que el `documento` del lector y la combinación `ISBN` + `num_ejemplar` existan en las tablas `biblioteca.usuario` y `biblioteca.ejemplar`.
* **Validación cronológica**: Revisa que la `fecha_pactada` sea igual o posterior a la `fecha_prestamo`.

---

## 2. Entregable 2 · Mapeo CSV → Esquema y criterios de error

### 2.1 Mapeo `prestamos_propios.csv` → Esquema `biblioteca.prestamo`

| Columna CSV | Tabla.columna destino | Transformación | Regla de validación (Motivo de rechazo) |
| --- | --- | --- | --- |
| `id_prestamo` | `PRESTAMO.id_prestamo` | `trim` | Vacío → «id_prestamo vacío» · `EXISTS` en `PRESTAMO` → «id_prestamo ya existe» · Repetido en CSV → «id_prestamo repetido en el archivo» |
| `isbn` | `PRESTAMO.ISBN` | `trim` | `NOT EXISTS` en `EJEMPLAR` → «ISBN o ejemplar no existe en el catálogo» |
| `num_ejemplar` | `PRESTAMO.num_ejemplar` | `trim` + `::integer` | Regex non-numeric → «número de ejemplar no numérico» |
| `documento` | `PRESTAMO.id_usuario` | `trim` | `NOT EXISTS` en `USUARIO` → «usuario/documento no existe en el sistema» |
| `fecha_prestamo` | `PRESTAMO.fecha_prestamo` | `::date` | Formato fecha inválido → «fecha_prestamo mal formada» |
| `fecha_pactada` | `PRESTAMO.fecha_pactada` | `::date` | `fecha_pactada < fecha_prestamo` → «fecha pactada anterior a la fecha de préstamo» |
| `fecha_real` | `PRESTAMO.fecha_real` | `::date` (opcional) | Formato fecha inválido → «fecha_real mal formada» |
| `estado_mora` | `PRESTAMO.estado_mora` | `trim` | Guardado estático inicial (`'Sin mora'` / `'Con mora'`) |

### 2.2 Criterios de rechazo para el archivo `prestamos_propios.csv`

| Línea | Registro | Problema detectado | Motivo en `carga.rechazo_carga` | Decisión |
| --- | --- | --- | --- | --- |
| 7 | `PRES-P006` | ISBN inexistente (`9789999999999`) | ISBN o ejemplar no existe en el catálogo | Rechazar |
| 8 | `PRES-P007` | Usuario no registrado (`9999999999`) | usuario/documento no existe en el sistema | Rechazar |
| 9 | `PRES-P008` | `fecha_pactada` (`2024-03-10`) < `fecha_prestamo` (`2024-03-26`) | fecha pactada anterior a la fecha de préstamo | Rechazar |

---

## 3. Entregable 3 · Definición del CSV propio de préstamos

El archivo `postgres/scripts/datos/prestamos_propios.csv` se estructuró con 5 filas válidas que referencian libros y usuarios cargados previamente, y 3 casos de falla:

```csv
id_prestamo,isbn,num_ejemplar,documento,fecha_prestamo,fecha_pactada,fecha_real,estado_mora
PRES-P001,9788420471839,1,1001002001,2024-03-01,2024-03-15,2024-03-12,Sin mora
PRES-P002,9788420471839,2,1001002002,2024-03-05,2024-03-19,,Sin mora
PRES-P003,9788437604947,1,1001002003,2024-03-10,2024-03-24,2024-03-26,Con mora
PRES-P004,9788497592208,1,1001002004,2024-03-15,2024-03-29,,Sin mora
PRES-P005,9788437621494,1,1001002005,2024-03-20,2024-04-03,2024-03-30,Sin mora
PRES-P006,9789999999999,1,1001002001,2024-03-22,2024-04-05,,Sin mora
PRES-P007,9788420471839,1,9999999999,2024-03-25,2024-04-08,,Sin mora
PRES-P008,9788437604947,1,1001002002,2024-03-26,2024-03-10,,Sin mora

```

---

## 4. Entregable 4 · Salidas de `psql` y ejecución de reportes (S15)

### 4.1 Carga de préstamos propios (`prestamos_propios.csv`)

Ejecución en PowerShell / Terminal:

```bash
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_propios.csv -f /scripts/S15-carga-prestamos.sql

```

Salida de la ejecución:

```
BEGIN
NOTICE:  schema "carga" already exists, skipping
CREATE SCHEMA
NOTICE:  relation "stg_prestamo" already exists, skipping
CREATE TABLE
TRUNCATE TABLE
TRUNCATE TABLE
COPY 9
DELETE 1
DELETE 0
INSERT 0 8
UPDATE 8
UPDATE 0
INSERT 0 3
INSERT 0 5
COMMIT
 cargadas | rechazadas
----------+------------
        5 |          3
(1 row)

```

Consulta de verificación de la bitácora (`carga.rechazo_carga`):

```bash
docker compose exec postgres psql -U curso -d curso -c "SELECT linea, motivo FROM carga.rechazo_carga WHERE archivo LIKE '%prestamos_propios.csv' ORDER BY linea;"

```

```
 linea |                         motivo                         
-------+--------------------------------------------------------
     7 | ISBN o ejemplar no existe en el catálogo
     8 | usuario/documento no existe en el sistema
     9 | fecha pactada anterior a la fecha de préstamo
(3 rows)

```

---

### 4.2 Reportes de negocio SQL (`S15-reportes.sql`)

Ejecución del script consolidado de reportes:

```bash
docker compose exec postgres psql -U curso -d curso -P pager=off -f /scripts/S15-reportes.sql

```

#### Reporte 1: Top 5 libros más prestados

```
               titulo                | total_prestamos 
-------------------------------------+-----------------
 Cien anos de soledad                |               2
 Pedro Paramo                        |               1
 La ciudad y los perros              |               1
 Rayuela                             |               1
(4 rows)

```

#### Reporte 2: Lectores con más entregas completadas (`fecha_real IS NOT NULL`)

```
     lector     | entregas_completadas 
----------------+----------------------
 Andres Gomez   |                    1
 Camilo Ruiz    |                    1
 Esteban Rios   |                    1
(3 rows)

```

#### Reporte 3: Lectores con préstamos en mora

```
     lector     |          correo           |  telefono  | prestamos_en_mora 
----------------+---------------------------+------------+-------------------
 Beatriz Lopez  | beatriz.lopez@test.com    | 3002345678 |                 1
 Daniela Morales| daniela.morales@test.com  | 3004567890 |                 1
(2 rows)

```

#### Reporte 4: Detalle de préstamos en mora y días transcurridos

Calcula la cantidad de días de mora restando `CURRENT_DATE - fecha_pactada` y proyecta el estado `'Con mora'`:

```
     lector     |         correo          |  telefono  |         titulo         | num_ejemplar | fecha_pactada | dias_mora | estado_mora 
----------------+-------------------------+------------+------------------------+--------------+---------------+-----------+-------------
 Beatriz Lopez  | beatriz.lopez@test.com  | 3002345678 | Cien anos de soledad   |            2 | 2024-03-19    |       963 | Con mora
 Daniela Morales| daniela.morales@test.com| 3004567890 | La ciudad y los perros |            1 | 2024-03-29    |       953 | Con mora
(2 rows)

```

---

## 5. Detalle de cambios por Pull Request y estructura del árbol Git

A continuación se detallan las ramas de desarrollo integradas a la rama principal `main`, en concordancia con el historial del repositorio:

| Rama | Estado / PR | Descripción y alcance |
| --- | --- | --- |
| `feature-10/correccion_y_reportes` | Merged (PR #10) | **Entrega S15**: Creación de la tabla `stg_prestamo`, usuario `'BIBLIO-001'`, carga masiva de préstamos y reportes SQL dinámicos con cálculo de mora por `CURRENT_DATE`. |
| `feature/08-carga-prestamos` | Integrated | Desarrollo preliminar del script de carga de préstamos y archivo de pruebas `prestamos_semilla_con_errores.csv`. |
| `feature-07/docker_compose_correjido` | Merged (PR #9) | Corrección de volúmenes y rutas en `docker-compose.yml` para despliegue en entornos limpios. |
| `Correcion02` | Merged (PR #8) | Ajuste de inconsistencias de nombres de esquema y sintaxis SQL en scripts de inicialización. |
| `correcion01` | Merged (PR #7) | Normalización de restricciones FK y tipos de datos en tablas relacionales. |
| `feature06/correcion_tablas` | Merged (PR #6) | Corrección estructural en los tipos de datos del esquema base (`01_esquema.sql`). |
| `feature-05/informe` | Merged (PR #4) | Estructuración inicial de la documentación del Hito 2 en Markdown. |
| `feature/04-csv-propio` | Merged (PR #3) | Incorporación de datasets propios (`libros_propio.csv`, `lectores_propio.csv`) y pruebas de validación de staging. |
| `feature/03-carga-lectores` | Merged (PR #2) | Carga masiva de usuarios y roles mediante `S14-carga-lectores.sql`. |
| `feature/02-carga-libros` | Merged (PR #1) | Carga masiva del catálogo de libros y ejemplares mediante `S14-carga-libros.sql`. |

---

## 6. Checklist de cumplimiento Hito 2 (S14 - S15)

| Criterio | Nivel alcanzado | Evidencia en este informe |
| --- | --- | --- |
| **Esquema de arranque autoejecutable** | **OK** | §1.1 — `01_esquema.sql` crea tablas, extensiones (`pgcrypto`) y usuarios iniciales al desplegar Docker. |
| **ETL de Libros, Lectores y Préstamos** | **OK** | §1.2 y §4.1 — Transacciones atómicas, tablas staging y manejo de `COPY`. |
| **Manejo de errores y bitácora de rechazos** | **OK** | §2.2 y §4.1 — Atrapamiento de filas defectuosas en `carga.rechazo_carga` sin cancelar la transacción de filas válidas. |
| **Pruebas con datos semilla y datos propios** | **OK** | §3 y §4.1 — Validación con 5 cargadas y 3 rechazadas por cada dataset propio. |
| **Suite de Reportes SQL (S15)** | **OK** | §4.2 — Evaluación dinámica de préstamos morosos e indicadores de biblioteca. |

---

## 7. Instrucciones para reproducción del entorno

Para desplegar la base de datos y ejecutar la suite completa de cargas y reportes desde una terminal limpia:

```bash
# 1. Levantar el contenedor de PostgreSQL
docker compose up -d postgres

# 2. Ejecutar carga masiva de Lectores (Semilla, Errores y Propio)
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_semilla.csv -f /scripts/S14-carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_semilla_con_errores.csv -f /scripts/S14-carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_propio_2.csv -f /scripts/S14-carga-lectores.sql

# 3. Ejecutar carga masiva de Libros (Semilla, Errores y Propio)
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_semilla.csv -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_semilla_con_errores.csv -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_propio_2.csv -f /scripts/S14-carga-libros.sql

# 4. Ejecutar carga masiva de Préstamos (Semilla, Errores y Propio)
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_semilla.csv -f /scripts/S15-carga-prestamos.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_semilla_con_erorres.csv -f /scripts/S15-carga-prestamos.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_propios_2.csv -f /scripts/S15-carga-prestamos.sql

# 5. Generar la suite de reportes de negocio
docker compose exec postgres psql -U curso -d curso -P pager=off -f /scripts/S15-reportes.sql

```
