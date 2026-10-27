-- =====================================================================
-- carga-libros.sql  ·  S14 · carga de libros desde CSV al esquema del grupo
--
-- Patrón: tabla de paso -> validación -> tablas finales -> bitácora,
-- todo dentro de una transacción.
--
-- Uso (desde la raíz del proyecto, PowerShell, en una sola línea):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/carga-libros.sql
--   docker compose exec postgres psql -U curso -d curso -v archivo=/scripts/datos/libros_semilla_con_errores.csv -f /scripts/carga-libros.sql
--
-- Columnas esperadas del CSV (6):
--   isbn, titulo, autor, categoria, anio_publicacion, ejemplares_disponibles
-- =====================================================================

\set ON_ERROR_STOP on

-- Archivo por defecto: el CSV limpio
\if :{?archivo}
\else
  \set archivo '/scripts/datos/libros_semilla.csv'
\endif

-- ---------------------------------------------------------------------
-- Objetos de apoyo, en un esquema aparte para no mezclarlos con el modelo.
-- La bitácora es compartida con la carga de lectores.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS carga;

CREATE TABLE IF NOT EXISTS carga.rechazo_carga (
    id        serial      PRIMARY KEY,
    archivo   text        NOT NULL,
    linea     integer     NOT NULL,
    contenido text,
    motivo    text        NOT NULL,
    fecha     timestamptz NOT NULL DEFAULT now()
);

-- Una fila por línea del archivo, sin interpretar. n = número de línea.
CREATE TABLE IF NOT EXISTS carga.stg_linea (
    n     integer GENERATED ALWAYS AS IDENTITY,
    linea text
);

-- Tabla de paso: todo como texto, sin restricciones.
CREATE TABLE IF NOT EXISTS carga.stg_libro (
    linea_csv              integer,
    contenido              text,
    num_campos             integer,
    isbn                   text,
    titulo                 text,
    autor                  text,
    categoria              text,
    anio_publicacion       text,
    ejemplares_disponibles text,
    motivo                 text      -- NULL = la fila pasó todas las reglas
);

BEGIN;

TRUNCATE carga.stg_linea RESTART IDENTITY;
TRUNCATE carga.stg_libro;

-- Paso 1. Leer el archivo tal cual: FORMAT text separa por tabulador,
-- que no aparece en el CSV, así cada línea entera cae en una columna.
COPY carga.stg_linea (linea) FROM :'archivo' WITH (FORMAT text);
DELETE FROM carga.stg_linea WHERE n = 1;                  -- encabezado
DELETE FROM carga.stg_linea WHERE trim(linea) = '';       -- líneas en blanco

-- Paso 2. Partir cada línea en campos (todavía texto; vacío = '', no NULL).
INSERT INTO carga.stg_libro
SELECT n,
       rtrim(linea, E'\r'),
       COALESCE(array_length(string_to_array(rtrim(linea, E'\r'), ','), 1), 0),
       trim(split_part(linea, ',', 1)),
       trim(split_part(linea, ',', 2)),
       trim(split_part(linea, ',', 3)),
       trim(split_part(linea, ',', 4)),
       trim(split_part(linea, ',', 5)),
       trim(replace(split_part(linea, ',', 6), E'\r', ''))
FROM carga.stg_linea;

-- Paso 3. Validar. El CASE se detiene en la primera regla que falla;
-- sin ELSE devuelve NULL (la fila pasó). El ORDEN IMPORTA: cada ::integer
-- va después de la regla que comprueba que el texto son dígitos.
UPDATE carga.stg_libro SET motivo = CASE
    WHEN num_campos <> 6
         THEN 'tiene ' || num_campos || ' columnas, se esperaban 6'
    WHEN isbn = ''                                   THEN 'isbn vacío'
    WHEN isbn !~ '^[0-9]{13}$'                       THEN 'isbn no tiene 13 dígitos'
    WHEN titulo = ''                                 THEN 'título vacío'
    WHEN autor = ''                                  THEN 'autor vacío'
    WHEN categoria = ''                              THEN 'categoría vacía'
    WHEN anio_publicacion !~ '^[0-9]{1,4}$'          THEN 'año no numérico'
    WHEN anio_publicacion::integer
         NOT BETWEEN 1450 AND extract(year FROM current_date)::integer
                                                     THEN 'año fuera de rango'
    WHEN ejemplares_disponibles !~ '^-?[0-9]{1,4}$'  THEN 'ejemplares no numérico'
    WHEN ejemplares_disponibles::integer < 0         THEN 'ejemplares negativo'
    WHEN EXISTS (SELECT 1 FROM "LIBRO" l
                 WHERE l."ISBN" = carga.stg_libro.isbn)
                                                     THEN 'isbn ya existe en el catálogo'
END;

-- Paso 4. Duplicados dentro del mismo archivo: se conserva la primera
-- aparición válida y se rechazan las siguientes.
UPDATE carga.stg_libro s
SET motivo = 'isbn repetido en el archivo'
WHERE s.motivo IS NULL
  AND EXISTS (SELECT 1 FROM carga.stg_libro p
              WHERE p.isbn = s.isbn
                AND p.motivo IS NULL
                AND p.linea_csv < s.linea_csv);

-- Paso 5. Pasar las válidas a las tablas finales, en orden de dependencia.
-- Los ids son varchar sin valor por defecto: 'CAT-001', 'AUT-0001', ...
-- continúan desde el mayor que ya exista, así la carga se puede repetir.

-- 5a. Categorías nuevas
INSERT INTO "CATEGORIA" (id_categoria, nombre)
SELECT 'CAT-' || lpad((m.max_n + row_number() OVER (ORDER BY n.categoria))::text, 3, '0'),
       n.categoria
FROM (SELECT DISTINCT s.categoria
      FROM carga.stg_libro s
      WHERE s.motivo IS NULL
        AND NOT EXISTS (SELECT 1 FROM "CATEGORIA" c WHERE c.nombre = s.categoria)) n
CROSS JOIN (SELECT COALESCE(max(substring(id_categoria FROM '[0-9]+$')::integer), 0) AS max_n
            FROM "CATEGORIA") m;

-- 5b. Autores nuevos (nacionalidad no viene en el CSV: queda NULL)
INSERT INTO "AUTOR" (id_autor, nombre)
SELECT 'AUT-' || lpad((m.max_n + row_number() OVER (ORDER BY n.autor))::text, 4, '0'),
       n.autor
FROM (SELECT DISTINCT s.autor
      FROM carga.stg_libro s
      WHERE s.motivo IS NULL
        AND NOT EXISTS (SELECT 1 FROM "AUTOR" a WHERE a.nombre = s.autor)) n
CROSS JOIN (SELECT COALESCE(max(substring(id_autor FROM '[0-9]+$')::integer), 0) AS max_n
            FROM "AUTOR") m;

-- 5c. Libros (editorial no viene en el CSV: queda NULL)
INSERT INTO "LIBRO" ("ISBN", id_categoria, titulo, ano_publicacion)
SELECT s.isbn, c.id_categoria, s.titulo, s.anio_publicacion::integer
FROM carga.stg_libro s
JOIN "CATEGORIA" c ON c.nombre = s.categoria
WHERE s.motivo IS NULL;

-- 5d. Relación libro-autor
INSERT INTO "LIBRO_AUTOR" ("ISBN", id_autor)
SELECT s.isbn, a.id_autor
FROM carga.stg_libro s
JOIN "AUTOR" a ON a.nombre = s.autor
WHERE s.motivo IS NULL;

-- 5e. Ejemplares: ejemplares_disponibles = n  ->  n filas (1..n)
INSERT INTO "EJEMPLAR" ("ISBN", num_ejemplar, estado)
SELECT s.isbn, g.n::text, 'disponible'
FROM carga.stg_libro s
CROSS JOIN LATERAL generate_series(1, s.ejemplares_disponibles::integer) AS g(n)
WHERE s.motivo IS NULL;

-- Paso 6. Bitácora de rechazos
INSERT INTO carga.rechazo_carga (archivo, linea, contenido, motivo)
SELECT :'archivo', linea_csv, contenido, motivo
FROM carga.stg_libro
WHERE motivo IS NOT NULL;

COMMIT;

-- Resumen de la carga
SELECT count(*) FILTER (WHERE motivo IS NULL)     AS cargadas,
       count(*) FILTER (WHERE motivo IS NOT NULL) AS rechazadas
FROM carga.stg_libro;

SELECT linea_csv AS linea, motivo, contenido
FROM carga.stg_libro
WHERE motivo IS NOT NULL
ORDER BY linea_csv;
