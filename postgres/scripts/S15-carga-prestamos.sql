CREATE SCHEMA IF NOT EXISTS carga;

CREATE TABLE IF NOT EXISTS carga.stg_prestamo (
    linea_csv      integer,
    contenido      text,
    num_campos     integer,
    id_prestamo    text,
    isbn           text,
    num_ejemplar   text,
    documento      text,
    fecha_prestamo text,
    fecha_pactada  text,
    fecha_real     text,
    estado_mora    text,
    motivo         text
);

TRUNCATE carga.stg_linea RESTART IDENTITY;
TRUNCATE carga.stg_prestamo;

-- Paso 1. Leer el archivo línea por línea
COPY carga.stg_linea (linea) FROM :'archivo' WITH (FORMAT text);
DELETE FROM carga.stg_linea WHERE n = 1;                  -- Elimina encabezado
DELETE FROM carga.stg_linea WHERE trim(linea) = '';       -- Elimina líneas vacías

-- Paso 2. Separar campos
INSERT INTO carga.stg_prestamo (linea_csv, contenido, num_campos,
                                id_prestamo, isbn, num_ejemplar, documento,
                                fecha_prestamo, fecha_pactada, fecha_real, estado_mora)
SELECT n,
       rtrim(linea, E'\r'),
       COALESCE(array_length(string_to_array(rtrim(linea, E'\r'), ','), 1), 0),
       trim(split_part(linea, ',', 1)),
       trim(split_part(linea, ',', 2)),
       trim(split_part(linea, ',', 3)),
       trim(split_part(linea, ',', 4)),
       trim(split_part(linea, ',', 5)),
       trim(split_part(linea, ',', 6)),
       trim(split_part(linea, ',', 7)),
       trim(replace(split_part(linea, ',', 8), E'\r', ''))
FROM carga.stg_linea;

-- Paso 3. Validaciones de negocio e integridad referencial
UPDATE carga.stg_prestamo SET motivo = CASE
    WHEN num_campos <> 8
         THEN 'tiene ' || num_campos || ' columnas, se esperaban 8'
    WHEN id_prestamo = ''                               THEN 'id_prestamo vacío'
    WHEN isbn = ''                                      THEN 'isbn vacío'
    WHEN num_ejemplar = ''                              THEN 'número de ejemplar vacío'
    WHEN documento = ''                                 THEN 'documento de usuario vacío'
    WHEN fecha_prestamo = ''                            THEN 'fecha de préstamo vacía'
    WHEN fecha_prestamo !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                                                        THEN 'fecha de préstamo mal formada (esperada AAAA-MM-DD)'
    WHEN fecha_pactada = ''                             THEN 'fecha pactada vacía'
    WHEN fecha_pactada !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                                                        THEN 'fecha pactada mal formada (esperada AAAA-MM-DD)'
    WHEN fecha_pactada::date < fecha_prestamo::date     THEN 'fecha pactada anterior a la fecha de préstamo'
    WHEN fecha_real <> '' AND fecha_real !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                                                        THEN 'fecha real mal formada'
    WHEN fecha_real <> '' AND fecha_real::date < fecha_prestamo::date
                                                        THEN 'fecha real anterior a la fecha de préstamo'
    WHEN NOT EXISTS (SELECT 1 FROM biblioteca.usuario u WHERE u."id_usuario" = carga.stg_prestamo.documento)
                                                        THEN 'usuario no existe en la base de datos'
    WHEN NOT EXISTS (SELECT 1 FROM biblioteca.ejemplar e WHERE e."ISBN" = carga.stg_prestamo.isbn AND e."num_ejemplar" = carga.stg_prestamo.num_ejemplar)
                                                        THEN 'ejemplar no existe en el catálogo'
    WHEN EXISTS (SELECT 1 FROM biblioteca.prestamo p WHERE p."id_prestamo" = carga.stg_prestamo.id_prestamo)
                                                        THEN 'id_prestamo ya existe en la base de datos'
    WHEN EXISTS (SELECT 1 FROM biblioteca.prestamo p
                 WHERE p."ISBN" = carga.stg_prestamo.isbn
                   AND p."num_ejemplar" = carga.stg_prestamo.num_ejemplar
                   AND p."fecha_prestamo" = carga.stg_prestamo.fecha_prestamo::date)
                                                        THEN 'ya existe un préstamo de ese ejemplar en la misma fecha'
    WHEN fecha_real = ''
         AND EXISTS (SELECT 1 FROM biblioteca.prestamo p
                     WHERE p."ISBN" = carga.stg_prestamo.isbn
                       AND p."num_ejemplar" = carga.stg_prestamo.num_ejemplar
                       AND p."fecha_real" IS NULL)
                                                        THEN 'el ejemplar ya tiene un préstamo abierto'
END;

-- Paso 4. Duplicados dentro del mismo archivo
UPDATE carga.stg_prestamo s
SET motivo = CASE
    WHEN EXISTS (SELECT 1 FROM carga.stg_prestamo p
                 WHERE p.id_prestamo = s.id_prestamo
                   AND p.motivo IS NULL
                   AND p.linea_csv < s.linea_csv)
        THEN 'id_prestamo repetido en el archivo'
    WHEN EXISTS (SELECT 1 FROM carga.stg_prestamo p
                 WHERE p.isbn = s.isbn
                   AND p.num_ejemplar = s.num_ejemplar
                   AND p.fecha_prestamo = s.fecha_prestamo
                   AND p.motivo IS NULL
                   AND p.linea_csv < s.linea_csv)
        THEN 'préstamo duplicado (mismo ejemplar y fecha) en el archivo'
    WHEN s.fecha_real = ''
         AND EXISTS (SELECT 1 FROM carga.stg_prestamo p
                     WHERE p.isbn = s.isbn
                       AND p.num_ejemplar = s.num_ejemplar
                       AND p.fecha_real = ''
                       AND p.motivo IS NULL
                       AND p.linea_csv < s.linea_csv)
        THEN 'múltiples préstamos abiertos para el mismo ejemplar en el archivo'
END
WHERE s.motivo IS NULL;

-- Paso 5. Inserción de filas válidas en biblioteca.prestamo (sin estado_mora)
INSERT INTO biblioteca.prestamo ("id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
                                 "fecha_prestamo", "fecha_pactada", "fecha_real")
SELECT id_prestamo,
       isbn,
       num_ejemplar,
       documento,
       'BIBLIO-001',
       fecha_prestamo::date,
       fecha_pactada::date,
       NULLIF(fecha_real, '')::date
FROM carga.stg_prestamo
WHERE motivo IS NULL;

-- Paso 6. Mover filas inválidas a la bitácora
INSERT INTO carga.rechazo_carga (archivo, linea, contenido, motivo)
SELECT :'archivo', linea_csv, contenido, motivo
FROM carga.stg_prestamo
WHERE motivo IS NOT NULL;

COMMIT;

-- Resumen de ejecución
SELECT count(*) FILTER (WHERE motivo IS NULL)     AS cargadas,
       count(*) FILTER (WHERE motivo IS NOT NULL) AS rechazadas
FROM carga.stg_prestamo;

SELECT linea_csv AS linea, motivo, contenido
FROM carga.stg_prestamo
WHERE motivo IS NOT NULL
ORDER BY linea_csv;