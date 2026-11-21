# Proyecto Biblioteca · Esquema Relacional, Carga ETL, Reportes y Normalización (FNBC)

## Integrantes

- **Juan Pablo Lozano Restrepo** — `2521505`
- **Sebastián Martínez Cabrera** — `2519817`
- **Benjamin Lopera** — `2515144`
- **Jhonny Alexander Moreno** — `2522112`

**Curso:** 750006C Bases de Datos · Grupo 80 · **Grupo de proyecto:** 05

| Campo | Detalle |
| :--- | :--- |
| Repositorio | `proyecto-biblioteca` |
| Rama principal | `main` |
| Motor de base de datos | PostgreSQL 16 (`postgres:16`), BD `curso`, esquema `biblioteca` |
| Administrador web | pgAdmin 4 (`http://localhost:5050`) |
| Estado actual | **Hito 3 completado** — Esquema normalizado en **FNBC** (S14 – S20) |
| Última actualización | 20/11/2026 |

---

## 1. Estructura del repositorio

```text
proyecto-biblioteca/
├── docker-compose.yml                  # Servicios: postgres (5432), mongo (27017) y pgadmin (5050)
├── pgadmin/
│   └── servers.json                    # Conexión precargada al servidor PostgreSQL del proyecto
├── postgres/
│   ├── init/
│   │   └── 01_esquema.sql              # Esquema inicial en FNBC, restricciones, índices y vista_prestamo
│   └── scripts/
│       ├── datos/                      # Datasets CSV (semilla, con errores y propios)
│       ├── S14-carga-lectores.sql      # ETL staging y validación de usuarios/lectores
│       ├── S14-carga-libros.sql        # ETL staging de categorías, autores, libros y ejemplares
│       ├── S15-carga-prestamos.sql     # ETL staging de préstamos con validaciones de unicidad
│       ├── S15-reportes.sql            # Suite de 4 reportes de negocio sobre vista_prestamo
│       ├── casos.sql                   # Taller S19 (Parte A): migraciones de 4 casos de estudio
│       └── normalizacion.sql           # Migración transaccional a FNBC (auditoría + EXCEPT)
└── Entregas/
    ├── S18/
    │   └── S18-dependencias.md         # Claves candidatas y dependencias funcionales por tabla
    ├── S19/
    │   └── S19-parte-b-.md             # Diagnóstico de formas normales y evidencia SQL
    └── S20/
        └── Hito3-normalizacion.md      # Documento oficial del Hito 3 (antes/después e índices)
```

---

## 2. Guía paso a paso: despliegue y comprobación desde cero

Sigue estos pasos después de clonar el repositorio para levantar el entorno limpio, poblar la base de datos, generar los reportes y corroborar que la normalización del Hito 3 funciona correctamente.

### Paso 1 · Clonar el repositorio y levantar los contenedores

```bash
git clone https://github.com/<tu-usuario-o-org>/proyecto-biblioteca.git
cd proyecto-biblioteca

# Levantar PostgreSQL (ejecuta automáticamente postgres/init/01_esquema.sql) y pgAdmin
docker compose up -d postgres pgadmin
```

### Paso 2 · Ejecutar las cargas masivas (ETL con manejo de rechazos)

```bash
# 1. Carga de Lectores (semilla, errores y propios)
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_semilla.csv -f /scripts/S14-carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_semilla_con_errores.csv -f /scripts/S14-carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/lectores_propio.csv -f /scripts/S14-carga-lectores.sql

# 2. Carga de Libros y Ejemplares (semilla, errores y propios)
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_semilla.csv -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_semilla_con_errores.csv -f /scripts/S14-carga-libros.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_propio.csv -f /scripts/S14-carga-libros.sql

# 3. Carga de Préstamos (semilla, errores y propios)
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_semilla.csv -f /scripts/S15-carga-prestamos.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_semilla_con_errores.csv -f /scripts/S15-carga-prestamos.sql
docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/prestamos_propio.csv -f /scripts/S15-carga-prestamos.sql
```

Para inspeccionar las filas rechazadas registradas en la bitácora:

```bash
docker compose exec postgres psql -U curso -d curso -c "SELECT archivo, linea, motivo FROM carga.rechazo_carga ORDER BY id_rechazo;"
```

### Paso 3 · Ejecutar la suite de reportes de negocio

```bash
docker compose exec postgres psql -U curso -d curso -P pager=off -f /scripts/S15-reportes.sql
```

### Paso 4 · Comprobar el esquema normalizado (FNBC) en pgAdmin o `psql`

1. Abre **`http://localhost:5050`** en tu navegador (entra directo sin pantalla de login).
2. En el panel izquierdo despliega **Servers → Curso - PostgreSQL** (contraseña por defecto: `curso`) **→ Databases → `curso` → Schemas → `biblioteca`**, haz clic derecho y abre **Query Tool**.
3. Ejecuta las siguientes **4 consultas de comprobación**:

```sql
-- 1. Confirmar que prestamo está en FNBC (ya no contiene la columna derivada estado_mora)
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'biblioteca'
  AND table_name = 'prestamo'
ORDER BY ordinal_position;

-- 2. Verificar que biblioteca.vista_prestamo calcula dias_mora y estado_mora al vuelo
SELECT id_prestamo, "ISBN", num_ejemplar, fecha_prestamo, fecha_pactada, fecha_real, dias_mora, estado_mora
FROM biblioteca.vista_prestamo
ORDER BY fecha_pactada;

-- 3. Confirmar condición física normalizada en ejemplar ('bueno')
SELECT estado, count(*) AS total
FROM biblioteca.ejemplar
GROUP BY estado;

-- 4. Verificar índice único parcial (préstamos abiertos) e índices sobre claves foráneas
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'biblioteca'
ORDER BY tablename, indexname;
```

**Resultados esperados:**
- **Consulta 1:** Devuelve exactamente **8 columnas** (`id_prestamo`, `ISBN`, `num_ejemplar`, `id_usuario`, `id_bibliotecario`, `fecha_prestamo`, `fecha_pactada`, `fecha_real`), sin `estado_mora`.
- **Consulta 2:** Muestra los **10 préstamos** con `dias_mora` y `estado_mora` (`Sin mora` / `Con mora`) calculados dinámicamente respecto a `CURRENT_DATE`.
- **Consulta 3:** Agrupa los **111 ejemplares** bajo condición física válida (`bueno`).
- **Consulta 4:** Lista los **18 índices** del esquema `biblioteca`, incluyendo `uq_prestamo_abierto_ejemplar` (índice único parcial `WHERE fecha_real IS NULL`) y los índices sobre claves foráneas (`idx_ejemplar_isbn`, `idx_prestamo_ejemplar`, `idx_prestamo_usuario`, `idx_libro_categoria`).

#### Prueba negativa opcional (validación de integridad en `prestamo`)

Ejecuta esta sentencia para comprobar que el motor impide registrar un segundo préstamo abierto sobre un ejemplar que aún no ha sido devuelto (debe fallar con error `23505` por violar `uq_prestamo_abierto_ejemplar`):

```sql
INSERT INTO biblioteca.prestamo (
    id_prestamo, "ISBN", num_ejemplar, id_usuario, id_bibliotecario, fecha_prestamo, fecha_pactada
)
SELECT 'PRUEBA-DUP', "ISBN", num_ejemplar, id_usuario, id_bibliotecario, CURRENT_DATE, CURRENT_DATE + 14
FROM biblioteca.prestamo
WHERE fecha_real IS NULL
LIMIT 1;
```

---

## 3. Resumen técnico por hitos

### Hito 2 (S14 – S16) · Esquema base, ETL staging y reportes
- **Patrón staging transaccional:** Los scripts `S14-carga-lectores.sql`, `S14-carga-libros.sql` y `S15-carga-prestamos.sql` cargan los CSV en tablas temporales sin restricciones (`carga.stg_*`), aplican reglas de formato e integridad referencial, insertan las filas válidas en `biblioteca.*` y derivan las inválidas a `carga.rechazo_carga` dentro de una transacción `BEGIN ... COMMIT`.
- **Idempotencia:** La reejecución de cualquiera de los scripts de carga no duplica registros; las filas ya existentes se derivan a la bitácora con su motivo correspondiente.
- **Usuario auditor por defecto:** `01_esquema.sql` habilita `pgcrypto` y crea el usuario `'BIBLIO-001'` (`Bibliotecario de Turno`) para referenciar préstamos cargados por lote.

### Hito 3 (S18 – S20) · Análisis de dependencias y normalización a FNBC
- **Eliminación de dato derivado (`prestamo.estado_mora`):** Al depender de `{"fecha_pactada", "fecha_real"}` (que no es superclave) y de `CURRENT_DATE`, la columna física quedaba desactualizada en préstamos abiertos. Se retiró de `prestamo` llevando las 8 tablas del esquema a **FNBC**, y se expuso mediante la vista **`biblioteca.vista_prestamo`**.
- **Protección de claves candidatas y reglas temporales:** Se añadió `UNIQUE ("ISBN", "num_ejemplar", "fecha_prestamo")`, el índice único parcial `uq_prestamo_abierto_ejemplar` (`WHERE "fecha_real" IS NULL`) y restricciones `CHECK` cronológicas (`fecha_pactada >= fecha_prestamo` y `fecha_real >= fecha_prestamo`).
- **Condición física en `ejemplar`:** Se estandarizó `ejemplar.estado` a condición física (`'bueno'`, `'regular'`, `'dañado'`, `'en reparación'`) con restricción `CHECK`, dejando la disponibilidad de préstamo deducible desde `prestamo`.
- **Optimización sin redundancia:** Se crearon índices sobre las claves foráneas más consultadas (`ejemplar("ISBN")`, `prestamo("ISBN", "num_ejemplar")`, `prestamo("id_usuario")`, `libro("id_categoria")`) evitando columnas calculadas redundantes.

---

## 4. Historial de integración en `main`

| Etapa / Rama | Alcance integrado |
| :--- | :--- |
| **Hito 3 (`S20`)** | Normalización de `biblioteca` a FNBC (`01_esquema.sql`, `normalizacion.sql`), adaptación de cargas/reportes a `vista_prestamo` y documento `Entregas/S20/Hito3-normalizacion.md`. |
| **Taller `S19`** | Corrección de migraciones en `postgres/scripts/casos.sql` y diagnóstico unificado de `biblioteca` en `Entregas/S19/S19-parte-b-.md`. |
| **Análisis `S18`** | Formalización de claves candidatas y dependencias funcionales en `Entregas/S18/S18-dependencias.md`. |
| **Hito 2 (`S14–S16`)** | Esquema inicial, scripts ETL (`S14-carga-*`, `S15-carga-prestamos.sql`), datasets semilla/propios y reportes SQL (`S15-reportes.sql`). |
```
