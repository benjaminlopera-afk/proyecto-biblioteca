-- =====================================================================
-- 01_esquema.sql  ·  esquema del proyecto biblioteca (normalizado - Hito 3)
-- Se ejecuta solo, una vez, cuando la base de Postgres se crea vacía.
--
-- Ajustes S14 y Hito 3 (S20):
--   * pgcrypto: para guardar la contraseña inicial de los lectores con hash
--   * UNIQUE en categoria.nombre y autor.nombre: carga idempotente
--   * CHECKs en libro y ejemplar (condición física controlada)
--   * prestamo en FNBC: se elimina el dato derivado estado_mora (expuesto
--     mediante biblioteca.vista_prestamo), se blinda la clave natural alterna
--     ("ISBN", "num_ejemplar", "fecha_prestamo") y se impiden préstamos
--     abiertos simultáneos sobre el mismo ejemplar con un índice único parcial
--   * Índices sobre claves foráneas frecuentes (rendimiento sin redundancia)
-- =====================================================================

-- Creación del esquema y configuración de búsqueda
CREATE SCHEMA IF NOT EXISTS biblioteca;
SET search_path TO biblioteca, public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE categoria (
  "id_categoria" varchar PRIMARY KEY,
  "nombre" varchar UNIQUE NOT NULL
);

CREATE TABLE autor (
  "id_autor" varchar PRIMARY KEY,
  "nombre" varchar UNIQUE NOT NULL,
  "nacionalidad" varchar
);

CREATE TABLE libro (
  "ISBN" varchar PRIMARY KEY,
  "id_categoria" varchar NOT NULL,
  "titulo" varchar NOT NULL,
  "editorial" varchar,
  "ano_publicacion" int,
  CONSTRAINT "chk_libro_isbn" CHECK ("ISBN" ~ '^[0-9]{13}$'),
  CONSTRAINT "chk_libro_titulo" CHECK (btrim("titulo") <> ''),
  CONSTRAINT "chk_libro_ano" CHECK ("ano_publicacion" BETWEEN 1450 AND 2100)
);

CREATE TABLE libro_autor (
  "ISBN" varchar,
  "id_autor" varchar,
  PRIMARY KEY ("ISBN", "id_autor")
);

CREATE TABLE ejemplar (
  "ISBN" varchar,
  "num_ejemplar" varchar,
  "estado" varchar NOT NULL,
  "ubicacion" varchar,
  PRIMARY KEY ("ISBN", "num_ejemplar"),
  CONSTRAINT "chk_ejemplar_estado" CHECK ("estado" IN ('bueno', 'regular', 'dañado', 'en reparación'))
);

CREATE TABLE rol (
  "id_rol" varchar PRIMARY KEY,
  "nombre_rol" varchar UNIQUE NOT NULL
);

CREATE TABLE usuario (
  "id_usuario" varchar PRIMARY KEY,
  "id_rol" varchar NOT NULL,
  "nombre" varchar NOT NULL,
  "correo" varchar UNIQUE NOT NULL,
  "telefono" varchar,
  "contrasena" varchar NOT NULL
);

CREATE TABLE prestamo (
  "id_prestamo" varchar PRIMARY KEY,
  "ISBN" varchar NOT NULL,
  "num_ejemplar" varchar NOT NULL,
  "id_usuario" varchar NOT NULL,
  "id_bibliotecario" varchar NOT NULL,
  "fecha_prestamo" date NOT NULL,
  "fecha_pactada" date NOT NULL,
  "fecha_real" date,
  CONSTRAINT "uq_prestamo_ejemplar_fecha" UNIQUE ("ISBN", "num_ejemplar", "fecha_prestamo"),
  CONSTRAINT "chk_prestamo_fecha_pactada" CHECK ("fecha_pactada" >= "fecha_prestamo"),
  CONSTRAINT "chk_prestamo_fecha_real" CHECK ("fecha_real" IS NULL OR "fecha_real" >= "fecha_prestamo")
);

-- Claves foráneas
ALTER TABLE libro ADD FOREIGN KEY ("id_categoria") REFERENCES biblioteca.categoria ("id_categoria") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE usuario ADD FOREIGN KEY ("id_rol") REFERENCES biblioteca.rol ("id_rol") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE libro_autor ADD FOREIGN KEY ("ISBN") REFERENCES biblioteca.libro ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE libro_autor ADD FOREIGN KEY ("id_autor") REFERENCES biblioteca.autor ("id_autor") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE ejemplar ADD FOREIGN KEY ("ISBN") REFERENCES biblioteca.libro ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("id_usuario") REFERENCES biblioteca.usuario ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("ISBN", "num_ejemplar") REFERENCES biblioteca.ejemplar ("ISBN", "num_ejemplar") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("id_bibliotecario") REFERENCES biblioteca.usuario ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE;

-- Índice único parcial: impide prestar dos veces un ejemplar con préstamo abierto
CREATE UNIQUE INDEX "uq_prestamo_abierto_ejemplar"
  ON biblioteca.prestamo ("ISBN", "num_ejemplar")
  WHERE "fecha_real" IS NULL;

-- Índices sobre claves foráneas frecuentes (mejora de joins sin redundancia)
CREATE INDEX "idx_ejemplar_isbn"     ON biblioteca.ejemplar ("ISBN");
CREATE INDEX "idx_prestamo_ejemplar" ON biblioteca.prestamo ("ISBN", "num_ejemplar");
CREATE INDEX "idx_prestamo_usuario"  ON biblioteca.prestamo ("id_usuario");
CREATE INDEX "idx_libro_categoria"   ON biblioteca.libro ("id_categoria");

-- Vista que expone el atributo derivado estado_mora y dias_mora calculados al vuelo
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

-- Inserción inicial de roles del sistema
INSERT INTO biblioteca.rol ("id_rol", "nombre_rol") VALUES
  ('ADMIN', 'Administrador'),
  ('BIBLIO', 'Bibliotecario'),
  ('LECTOR', 'Lector'),
  ('AUDITOR', 'Auditor')
ON CONFLICT ("id_rol") DO NOTHING;

-- Usuario bibliotecario por defecto para auditoría del sistema
INSERT INTO biblioteca.usuario ("id_usuario", "id_rol", "nombre", "correo", "telefono", "contrasena")
VALUES (
  'BIBLIO-001',
  'BIBLIO',
  'Bibliotecario de Turno',
  'biblioteca@gmail.com',
  '3000000000',
  crypt('admin123', gen_salt('bf'))
)
ON CONFLICT ("id_usuario") DO NOTHING;