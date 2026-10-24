-- carga-lectores.sql
-- Carga de lectores desde CSV adaptada al esquema biblioteca-v2 / 01_esquema.sql

\set ON_ERROR_STOP on

\if :{?archivo}
\else
    \set archivo /scripts/datos/lectores_semilla.csv
\endif

BEGIN;

-- Se decide crear las tablas de paso y la bitacoras de rechazo
CREATE UNLOGGED TABLE IF NOT EXISTS stg_linea (
    n integer GENERATED ALWAYS AS IDENTITY,
    linea text
);

CREATE UNLOGGED TABLE IF NOT EXISTS stg_lector (
    linea_csv integer,
    contenido text,
    num_campos integer,
    documento text,
    nombres text,
    apellidos text,
    correo text,
    telefono text,
    motivo text
);

CREATE TABLE IF NOT EXISTS rechazo_carga (
    id_rechazo integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    archivo text NOT NULL,
    linea integer NOT NULL,
    contenido text NOT NULL,
    motivo text NOT NULL,
    fecha_registro timestamp DEFAULT current_timestamp
);

-- Se Limpian las tablas temporales antes de iniciar el proceso
TRUNCATE stg_linea, stg_lector RESTART IDENTITY;

-- Asegurar la existencia del rol 'LECTOR' en la tabla ROL
INSERT INTO "ROL" ("id_rol", "nombre_rol")
VALUES ('LECTOR', 'Lector')
ON CONFLICT ("id_rol") DO NOTHING;

-- Se lee el archivo linea por linea
COPY stg_linea (linea) FROM :'archivo' WITH (FORMAT text);
DELETE FROM stg_linea WHERE n = 1;       --elimina la primer linea que son los encabezados  

-- Se parte texto a campos individuales 
INSERT INTO stg_lector (linea_csv, contenido, num_campos,
                        documento, nombres, apellidos, correo, telefono)
SELECT n, linea,
       array_length(string_to_array(linea, ','), 1),
       trim(split_part(linea, ',', 1)),
       trim(split_part(linea, ',', 2)),
       trim(split_part(linea, ',', 3)),
       lower(trim(split_part(linea, ',', 4))),
       trim(split_part(linea, ',', 5))
FROM stg_linea;

-- Validaciones que dan el motivo de la falla 
UPDATE stg_lector SET motivo = CASE
    WHEN num_campos <> 5                          THEN 'tiene ' || num_campos || ' columnas, se esperaban 5'
    WHEN documento = ''                           THEN 'documento vacío'
    WHEN documento !~ '^[0-9]{6,15}$'             THEN 'documento no numérico o de longitud inválida'
    WHEN nombres = ''                             THEN 'nombres vacío'
    WHEN apellidos = ''                           THEN 'apellidos vacío'
    WHEN correo = ''                              THEN 'correo vacío'
    WHEN correo !~ '^[^@ ]+@[^@ ]+\.[^@ ]+$'      THEN 'correo mal formado'
    WHEN telefono !~ '^[0-9]{7,15}$'              THEN 'teléfono no numérico o de longitud inválida'
    WHEN EXISTS (SELECT 1 FROM "USUARIO" u WHERE u."id_usuario" = stg_lector.documento)
                                                  THEN 'documento ya existe'
    WHEN EXISTS (SELECT 1 FROM "USUARIO" u WHERE u."correo" = stg_lector.correo)
                                                  THEN 'correo ya registrado por otro usuario'
END;

-- Se detectan los duplicados en documento o correo
UPDATE stg_lector SET motivo = 'documento o correo repetido en el archivo'
WHERE motivo IS NULL
  AND EXISTS (SELECT 1 FROM stg_lector s2
              WHERE (s2.documento = stg_lector.documento OR s2.correo = stg_lector.correo)
                AND s2.motivo IS NULL
                AND s2.linea_csv < stg_lector.linea_csv);

-- Se insertan las filas validas a la tabla final 
INSERT INTO "USUARIO" ("id_usuario", "id_rol", "nombre", "correo", "telefono", "contrasena")
SELECT documento,
       'LECTOR',
       nombres || ' ' || apellidos,
       correo,
       telefono,
       documento -- Clave inicial provisional equivalente al documento
FROM stg_lector
WHERE motivo IS NULL;


-- Se insertan los valores rechazados a la bitacora de rechazados
INSERT INTO rechazo_carga (archivo, linea, contenido, motivo)
SELECT :'archivo', linea_csv, contenido, motivo
FROM stg_lector
WHERE motivo IS NOT NULL;

COMMIT;

-- Resumen de la carga 
SELECT count(*) FILTER (WHERE motivo IS NULL)     AS cargadas,
       count(*) FILTER (WHERE motivo IS NOT NULL) AS rechazadas
FROM stg_lector;

-- Se detallan los errores siempre y cuando existan
SELECT linea_csv AS linea, motivo, contenido
FROM stg_lector
WHERE motivo IS NOT NULL
ORDER BY linea_csv;