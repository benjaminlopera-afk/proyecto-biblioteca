-- =============================================================================
-- normalizacion.sql · Hito 3 (S20) · Migración a FNBC del esquema biblioteca
--
-- Mapa del script (siguiendo la guía de S19/S20):
--   1. Auditoría de dependencias y calidad de datos antes de migrar
--   2. Migración transaccional segura (BEGIN ... COMMIT):
--      - Normalización de ejemplar.estado (condición física)
--      - Reconstrucción de prestamo en FNBC (sin estado_mora, con UNIQUE natural,
--        índice único parcial para préstamos abiertos y CHECKs de fechas)
--      - Creación de índices sobre claves foráneas (rendimiento sin redundancia)
--      - Creación de vista biblioteca.vista_prestamo (dato derivado calculado)
--   3. Verificación por conteos y prueba sin pérdida (EXCEPT en ambos sentidos)
-- =============================================================================

\set ON_ERROR_STOP on

SET search_path TO biblioteca, public;

-- =============================================================================
-- 1. AUDITORÍA PREVIA DE DEPENDENCIAS Y CONSISTENCIA
-- =============================================================================

CREATE OR REPLACE TEMP VIEW auditoria_biblioteca AS
SELECT 1 AS n,
       'prestamo: clave natural alterna ("ISBN", "num_ejemplar", "fecha_prestamo") única' AS regla,
       (SELECT count(*) FROM (
            SELECT "ISBN", "num_ejemplar", "fecha_prestamo"
            FROM biblioteca.prestamo
            GROUP BY "ISBN", "num_ejemplar", "fecha_prestamo"
            HAVING count(*) > 1) t) AS violaciones
UNION ALL
SELECT 2,
       'prestamo: a lo sumo un préstamo abierto (fecha_real IS NULL) por ejemplar',
       (SELECT count(*) FROM (
            SELECT "ISBN", "num_ejemplar"
            FROM biblioteca.prestamo
            WHERE "fecha_real" IS NULL
            GROUP BY "ISBN", "num_ejemplar"
            HAVING count(*) > 1) t) AS violaciones
UNION ALL
SELECT 3,
       'prestamo: coherencia cronológica (fecha_pactada >= fecha_prestamo y fecha_real >= fecha_prestamo)',
       (SELECT count(*) FROM biblioteca.prestamo
        WHERE "fecha_pactada" < "fecha_prestamo"
           OR ("fecha_real" IS NOT NULL AND "fecha_real" < "fecha_prestamo")) AS violaciones;

SELECT n, regla, violaciones,
       CASE WHEN violaciones = 0 THEN 'se cumple' ELSE 'SE VIOLA' END AS estado
FROM auditoria_biblioteca
ORDER BY n;

-- Evidencia del problema en estado_mora (dato derivado desincronizado):
SELECT COALESCE("estado_mora", '(NULL)') AS estado_mora_guardado,
       (COALESCE("fecha_real", CURRENT_DATE) > "fecha_pactada") AS en_mora_real,
       count(*) AS filas
FROM biblioteca.prestamo
GROUP BY 1, 2
ORDER BY 1, 2;

-- =============================================================================
-- 2. MIGRACIÓN TRANSACCIONAL SEGURA
-- =============================================================================

DROP TABLE IF EXISTS esperados_biblioteca;
CREATE TEMP TABLE esperados_biblioteca AS
SELECT (SELECT count(*) FROM biblioteca.ejemplar) AS ejemplares,
       (SELECT count(*) FROM biblioteca.prestamo) AS prestamos;

BEGIN;

-- Guardia 1: abortar si los datos actuales violan las claves o reglas de fecha
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM auditoria_biblioteca WHERE violaciones > 0) THEN
        RAISE EXCEPTION 'Existen violaciones de integridad en prestamo: revisar auditoria_biblioteca antes de migrar';
    END IF;
END $$;

-- 2.1 Ajustar condición física en ejemplar ('disponible' era estado de préstamo, no condición física)
UPDATE biblioteca.ejemplar
SET "estado" = 'bueno'
WHERE lower(btrim("estado")) = 'disponible';

ALTER TABLE biblioteca.ejemplar
    DROP CONSTRAINT IF EXISTS "chk_ejemplar_estado";

ALTER TABLE biblioteca.ejemplar
    ADD CONSTRAINT "chk_ejemplar_estado"
    CHECK ("estado" IN ('bueno', 'regular', 'dañado', 'en reparación'));

-- 2.2 Respaldar tabla prestamo original
DROP VIEW IF EXISTS biblioteca.vista_prestamo;
ALTER TABLE biblioteca.prestamo RENAME TO prestamo_viejo;
ALTER INDEX IF EXISTS biblioteca.prestamo_pkey RENAME TO prestamo_viejo_pkey;

-- 2.3 Crear tabla prestamo normalizada en FNBC (sin columna derivada estado_mora)
CREATE TABLE biblioteca.prestamo (
    "id_prestamo"      varchar PRIMARY KEY,
    "ISBN"             varchar NOT NULL,
    "num_ejemplar"     varchar NOT NULL,
    "id_usuario"       varchar NOT NULL,
    "id_bibliotecario" varchar NOT NULL,
    "fecha_prestamo"   date    NOT NULL,
    "fecha_pactada"    date    NOT NULL,
    "fecha_real"       date,
    CONSTRAINT "uq_prestamo_ejemplar_fecha" UNIQUE ("ISBN", "num_ejemplar", "fecha_prestamo"),
    CONSTRAINT "chk_prestamo_fecha_pactada" CHECK ("fecha_pactada" >= "fecha_prestamo"),
    CONSTRAINT "chk_prestamo_fecha_real"    CHECK ("fecha_real" IS NULL OR "fecha_real" >= "fecha_prestamo"),
    FOREIGN KEY ("id_usuario")            REFERENCES biblioteca.usuario ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE,
    FOREIGN KEY ("ISBN", "num_ejemplar")  REFERENCES biblioteca.ejemplar ("ISBN", "num_ejemplar") DEFERRABLE INITIALLY IMMEDIATE,
    FOREIGN KEY ("id_bibliotecario")      REFERENCES biblioteca.usuario ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE
);

-- Índice único parcial: impide dos préstamos activos simultáneos sobre la misma copia física
CREATE UNIQUE INDEX "uq_prestamo_abierto_ejemplar"
    ON biblioteca.prestamo ("ISBN", "num_ejemplar")
    WHERE "fecha_real" IS NULL;

-- Índices sobre claves foráneas frecuentes (mejora de joins sin redundancia)
CREATE INDEX IF NOT EXISTS "idx_ejemplar_isbn"       ON biblioteca.ejemplar ("ISBN");
CREATE INDEX IF NOT EXISTS "idx_prestamo_ejemplar"   ON biblioteca.prestamo ("ISBN", "num_ejemplar");
CREATE INDEX IF NOT EXISTS "idx_prestamo_usuario"    ON biblioteca.prestamo ("id_usuario");
CREATE INDEX IF NOT EXISTS "idx_libro_categoria"     ON biblioteca.libro ("id_categoria");

-- 2.4 Copiar datos históricos hacia prestamo (excluyendo estado_mora)
INSERT INTO biblioteca.prestamo (
    "id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
    "fecha_prestamo", "fecha_pactada", "fecha_real"
)
SELECT
    "id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
    "fecha_prestamo", "fecha_pactada", "fecha_real"
FROM biblioteca.prestamo_viejo;

-- 2.5 Vista que expone el atributo derivado estado_mora y dias_mora calculados al vuelo
CREATE VIEW biblioteca.vista_prestamo AS
SELECT
    p."id_prestamo",
    p."ISBN",
    p."num_ejemplar",
    p."id_usuario",
    p."id_bibliotecario",
    p."fecha_prestamo",
    p."fecha_pactada",
    p."fecha_real",
    GREATEST(0, COALESCE(p."fecha_real", CURRENT_DATE) - p."fecha_pactada") AS "dias_mora",
    CASE
        WHEN COALESCE(p."fecha_real", CURRENT_DATE) > p."fecha_pactada" THEN 'Con mora'
        ELSE 'Sin mora'
    END AS "estado_mora"
FROM biblioteca.prestamo p;

-- =============================================================================
-- 3. VERIFICACIÓN DE MIGRACIÓN SIN PÉRDIDA
-- =============================================================================

-- 3.1 Conteos obtenidos vs esperados
SELECT tabla, obtenidas, esperadas, obtenidas = esperadas AS coincide
FROM (VALUES
    ('ejemplar', (SELECT count(*) FROM biblioteca.ejemplar), (SELECT ejemplares FROM esperados_biblioteca)),
    ('prestamo', (SELECT count(*) FROM biblioteca.prestamo), (SELECT prestamos  FROM esperados_biblioteca))
) AS t(tabla, obtenidas, esperadas);

-- 3.2 Prueba EXCEPT en ambos sentidos sobre los atributos base de prestamo
SELECT 'prestamo_viejo EXCEPT prestamo (se perdió algo)' AS prueba, count(*) AS filas
FROM (
    SELECT "id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
           "fecha_prestamo", "fecha_pactada", "fecha_real"
    FROM biblioteca.prestamo_viejo
    EXCEPT
    SELECT "id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
           "fecha_prestamo", "fecha_pactada", "fecha_real"
    FROM biblioteca.prestamo
) t
UNION ALL
SELECT 'prestamo EXCEPT prestamo_viejo (se inventó algo)', count(*)
FROM (
    SELECT "id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
           "fecha_prestamo", "fecha_pactada", "fecha_real"
    FROM biblioteca.prestamo
    EXCEPT
    SELECT "id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario",
           "fecha_prestamo", "fecha_pactada", "fecha_real"
    FROM biblioteca.prestamo_viejo
) t;

-- 3.3 Guardia final antes de eliminar la tabla antigua
DO $$
DECLARE e esperados_biblioteca%ROWTYPE;
BEGIN
    SELECT * INTO e FROM esperados_biblioteca;
    IF (SELECT count(*) FROM biblioteca.ejemplar) <> e.ejemplares
    OR (SELECT count(*) FROM biblioteca.prestamo) <> e.prestamos THEN
        RAISE EXCEPTION 'Los conteos tras la migración no coinciden: se aborta sin borrar prestamo_viejo';
    END IF;
END $$;

DROP VIEW auditoria_biblioteca;
DROP TABLE biblioteca.prestamo_viejo;

COMMIT;
DROP TABLE IF EXISTS esperados_biblioteca;