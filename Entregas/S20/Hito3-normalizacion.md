# Hito 3 · Análisis de Normalización y Esquema Actualizado (`biblioteca`)

**Curso:** 750006C Bases de Datos · Grupo 80  
**Grupo de proyecto:** 05  
**Integrantes:** Benjamin Lopera (`2515144`) · Sebastian Martinez (`2519817`) · Jhonny Moreno (`2522112`) · Juan Pablo Lozano Restrepo (`2521505`)

---

## 1. Esquema antes de la normalización

El esquema inicial (`postgres/init/01_esquema.sql` previo) estaba compuesto por ocho tablas relacionales en el esquema `biblioteca`:

- `categoria ("id_categoria" PK, "nombre" UNIQUE)`
- `autor ("id_autor" PK, "nombre" UNIQUE, "nacionalidad")`
- `libro ("ISBN" PK, "id_categoria" -> categoria, "titulo", "editorial", "ano_publicacion")`
- `libro_autor ("ISBN" -> libro, "id_autor" -> autor)` · `PK ("ISBN", "id_autor")`
- `ejemplar ("ISBN" -> libro, "num_ejemplar", "estado", "ubicacion")` · `PK ("ISBN", "num_ejemplar")`
- `rol ("id_rol" PK, "nombre_rol" UNIQUE)`
- `usuario ("id_usuario" PK, "id_rol" -> rol, "nombre", "correo" UNIQUE, "telefono", "contrasena")`
- `prestamo ("id_prestamo" PK, "ISBN", "num_ejemplar", "id_usuario" -> usuario, "id_bibliotecario" -> usuario, "fecha_prestamo", "fecha_pactada", "fecha_real", "estado_mora")` · `FK ("ISBN", "num_ejemplar") -> ejemplar`

---

## 2. Claves candidatas y dependencias funcionales por tabla

| Tabla | Claves candidatas | Dependencias funcionales no triviales y regla de negocio |
| :--- | :--- | :--- |
| `categoria` | `{"id_categoria"}`, `{"nombre"}` | `"id_categoria" → "nombre"` (cada código identifica una categoría); `"nombre" → "id_categoria"` (no existen dos categorías con el mismo nombre). |
| `autor` | `{"id_autor"}`, `{"nombre"}` | `"id_autor" → "nombre", "nacionalidad"` (cada código identifica un autor); `"nombre" → "id_autor", "nacionalidad"` (cada autor se registra con nombre único). |
| `libro` | `{"ISBN"}` | `"ISBN" → "id_categoria", "titulo", "editorial", "ano_publicacion"` (un ISBN identifica una edición bibliográfica única con categoría, título, editorial y año propios; `"titulo"` no es clave porque distintas ediciones pueden compartir título). |
| `libro_autor` | `{"ISBN", "id_autor"}` | Solo dependencias triviales (relación muchos a muchos entre libros y autores sin atributos propios; evita listas multivaluadas en `libro`). |
| `ejemplar` | `{"ISBN", "num_ejemplar"}` | `"ISBN", "num_ejemplar" → "estado", "ubicacion"` (cada copia física numerada dentro de un ISBN tiene una condición física y ubicación en estantería propias). |
| `rol` | `{"id_rol"}`, `{"nombre_rol"}` | `"id_rol" → "nombre_rol"` (cada código define un perfil del sistema); `"nombre_rol" → "id_rol"` (cada nombre de rol es único). |
| `usuario` | `{"id_usuario"}`, `{"correo"}` | `"id_usuario" → "id_rol", "nombre", "correo", "telefono", "contrasena"` (cada documento identifica a una persona); `"correo" → "id_usuario", "id_rol", "nombre", "telefono", "contrasena"` (el correo es único por cuenta). |
| `prestamo` | `{"id_prestamo"}`, `{"ISBN", "num_ejemplar", "fecha_prestamo"}` | `"id_prestamo" → "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario", "fecha_prestamo", "fecha_pactada", "fecha_real", "estado_mora"` (cada comprobante identifica una transacción); `"ISBN", "num_ejemplar", "fecha_prestamo" → ...` (una copia física no puede prestarse dos veces el mismo día); **`"fecha_pactada", "fecha_real" → "estado_mora"`** *(dependencia transitiva problemática: el estado de mora se deduce comparando las fechas contra `CURRENT_DATE`)*. |

*(Nota sobre `prestamo.fecha_pactada`: `"fecha_prestamo" ↛ "fecha_pactada"`, ya que el plazo acordado puede variar por tipo de usuario, políticas vigentes o renovaciones; es un dato histórico de cada préstamo).*

---

## 3. Forma normal por tabla y evidencia sobre los datos

| Tabla | Forma normal | Hallazgo y consulta SQL de evidencia | Resultado obtenido |
| :--- | :--- | :--- | :--- |
| `categoria`, `autor`, `rol` | **FNBC** | Sin anomalías. Claves naturales protegidas con `UNIQUE NOT NULL`.<br>`SELECT "nombre", count(*) FROM biblioteca.categoria GROUP BY 1 HAVING count(*) > 1;` | `0` filas duplicadas en las tres tablas. |
| `libro` | **FNBC** | Atributos atómicos. `"editorial"` se repite entre libros, pero ningún otro atributo depende de ella (sin dependencia transitiva).<br>`SELECT lower(btrim("editorial")), count(DISTINCT "editorial") FROM biblioteca.libro WHERE "editorial" IS NOT NULL GROUP BY 1 HAVING count(DISTINCT "editorial") > 1;` | `0` variantes inconsistentes. |
| `libro_autor` | **FNBC** | Tabla asociativa pura con clave compuesta; garantiza 1FN en `libro`. | Sin anomalías estructurales. |
| `ejemplar` | **FNBC** | En la carga inicial se insertaba `'disponible'` en `"estado"`, mezclando disponibilidad de préstamo (deducible desde `prestamo`) con condición física.<br>`SELECT "estado", count(*) FROM biblioteca.ejemplar GROUP BY 1;` | `111` filas con `'disponible'` → estandarizadas a condición física (`'bueno'`). |
| `usuario` | **FNBC** | Teléfono atómico (un valor por usuario) y correo único.<br>`SELECT count(*) FROM biblioteca.usuario WHERE "telefono" ~ '[,;/]';` | `0` filas multivaluadas. |
| `prestamo` | **2FN** *(antes)* → **FNBC** *(después)* | **(1) Dato derivado:** `{"fecha_pactada", "fecha_real"}` no es superclave y determina `"estado_mora"`, quedando desactualizado respecto a `CURRENT_DATE`.<br>**(2) Clave natural sin proteger:** faltaba `UNIQUE` en `("ISBN", "num_ejemplar", "fecha_prestamo")` e índice único parcial para préstamos abiertos.<br>`SELECT COALESCE("estado_mora",'(NULL)'), (COALESCE("fecha_real", CURRENT_DATE) > "fecha_pactada") AS en_mora_real, count(*) FROM biblioteca.prestamo GROUP BY 1, 2;` | `Con mora / t: 2`<br>`Sin mora / f: 4`<br>**`Sin mora / t: 4`** *(4 préstamos vencidos seguían marcados como `'Sin mora'`)*. |

---

## 4. Cambios aplicados y migración segura (`normalizacion.sql`)

Las correcciones se implementaron tanto en `postgres/init/01_esquema.sql` (para bases nuevas) como en la migración transaccional `postgres/scripts/normalizacion.sql` (`BEGIN ... COMMIT`):

1. **Eliminación de `prestamo.estado_mora` y creación de vista:** Se retiró la columna física `"estado_mora"` de `prestamo` y se creó `biblioteca.vista_prestamo`, que calcula dinámicamente `"dias_mora"` y `"estado_mora"` a partir de `"fecha_pactada"`, `"fecha_real"` y `CURRENT_DATE`.
2. **Protección de clave natural alterna y préstamos activos:** Se añadió `UNIQUE ("ISBN", "num_ejemplar", "fecha_prestamo")`, el índice único parcial `uq_prestamo_abierto_ejemplar` sobre `("ISBN", "num_ejemplar") WHERE "fecha_real" IS NULL` y restricciones `CHECK` cronológicas (`fecha_pactada >= fecha_prestamo` y `fecha_real >= fecha_prestamo`).
3. **Estandarización de `ejemplar.estado`:** Se actualizaron los 111 registros existentes de `'disponible'` a `'bueno'` y se agregó `CHECK ("estado" IN ('bueno', 'regular', 'dañado', 'en reparación'))`, ajustando también `S14-carga-libros.sql`, `S15-carga-prestamos.sql` y `S15-reportes.sql`.

| Verificación de migración (`normalizacion.sql`) | Obtenido | Esperado | Coincide |
| :--- | :---: | :---: | :---: |
| Conteo de filas en `biblioteca.ejemplar` | `111` | `111` | Sí (`t`) |
| Conteo de filas en `biblioteca.prestamo` | `10` | `10` | Sí (`t`) |
| `prestamo_viejo EXCEPT prestamo` (pérdida de datos) | `0` filas | `0` filas | Sí |
| `prestamo EXCEPT prestamo_viejo` (invención de datos) | `0` filas | `0` filas | Sí |

---

## 5. Decisión sobre desnormalizaciones e índices

- **Sin columnas derivadas almacenadas:** Se decidió **no desnormalizar** ni `prestamo.estado_mora` ni un contador `libro.ejemplares_disponibles`. Como demostró la auditoría de `prestamo`, almacenar datos calculables sin disparadores (`triggers`, alcance del Hito 4) provoca desincronizaciones silenciosas; calcularlos mediante `biblioteca.vista_prestamo` y agregaciones garantiza consistencia absoluta.
- **Dato histórico conservado:** `prestamo.fecha_pactada` permanece almacenada porque registra el acuerdo histórico vigente en el momento del préstamo, no una redundancia calculable.
- **Optimización mediante índices sin redundancia:** Para evitar recorridos secuenciales (`Seq Scan`) en las búsquedas del catálogo y reportes sin duplicar datos, se crearon índices sobre las claves foráneas más consultadas: `idx_ejemplar_isbn` en `ejemplar("ISBN")`, `idx_prestamo_ejemplar` en `prestamo("ISBN", "num_ejemplar")`, `idx_prestamo_usuario` en `prestamo("id_usuario")` e `idx_libro_categoria` en `libro("id_categoria")`.

---

## 6. Esquema después de la normalización (FNBC)

Todas las tablas del esquema `biblioteca` quedan en **Forma Normal de Boyce-Codd (FNBC)**, ya que en cada relación todo determinante no trivial es superclave:

- `categoria ("id_categoria" PK, "nombre" UNIQUE NOT NULL)` — **FNBC**
- `autor ("id_autor" PK, "nombre" UNIQUE NOT NULL, "nacionalidad")` — **FNBC**
- `libro ("ISBN" PK, "id_categoria" FK NOT NULL, "titulo" NOT NULL, "editorial", "ano_publicacion")` — **FNBC**
- `libro_autor ("ISBN" FK, "id_autor" FK)` · `PK ("ISBN", "id_autor")` — **FNBC**
- `ejemplar ("ISBN" FK, "num_ejemplar", "estado" NOT NULL, "ubicacion")` · `PK ("ISBN", "num_ejemplar")` — **FNBC**
- `rol ("id_rol" PK, "nombre_rol" UNIQUE NOT NULL)` — **FNBC**
- `usuario ("id_usuario" PK, "id_rol" FK NOT NULL, "nombre" NOT NULL, "correo" UNIQUE NOT NULL, "telefono", "contrasena" NOT NULL)` — **FNBC**
- `prestamo ("id_prestamo" PK, "ISBN", "num_ejemplar", "id_usuario" FK NOT NULL, "id_bibliotecario" FK NOT NULL, "fecha_prestamo" NOT NULL, "fecha_pactada" NOT NULL, "fecha_real")` · `FK ("ISBN", "num_ejemplar") -> ejemplar` · `UNIQUE ("ISBN", "num_ejemplar", "fecha_prestamo")` · Índice único parcial en `("ISBN", "num_ejemplar") WHERE "fecha_real" IS NULL` — **FNBC**
- **Vista derivada:** `biblioteca.vista_prestamo` (expone `"dias_mora"` y `"estado_mora"` calculados en tiempo de consulta; validada con los 4 reportes de `S15-reportes.sql`).