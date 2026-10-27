-- =====================================================================
-- 01_esquema.sql  ·  esquema del proyecto biblioteca
-- Se ejecuta solo, una vez, cuando la base de Postgres se crea vacía.
--
-- Ajustes para la carga S14 respecto al esquema original:
--   * pgcrypto: para guardar la contraseña inicial de los lectores con hash
--   * UNIQUE en CATEGORIA.nombre y AUTOR.nombre: la carga se puede repetir
--     sin duplicar categorías ni autores
--   * CHECKs en LIBRO: última línea de defensa tras las reglas del CASE
--     de carga-libros.sql
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE "CATEGORIA" (
  "id_categoria" varchar PRIMARY KEY,
  "nombre" varchar UNIQUE NOT NULL
);

CREATE TABLE "AUTOR" (
  "id_autor" varchar PRIMARY KEY,
  "nombre" varchar UNIQUE NOT NULL,
  "nacionalidad" varchar
);

CREATE TABLE "LIBRO" (
  "ISBN" varchar PRIMARY KEY,
  "id_categoria" varchar NOT NULL,
  "titulo" varchar NOT NULL,
  "editorial" varchar,
  "ano_publicacion" int,
  CONSTRAINT "chk_libro_isbn" CHECK ("ISBN" ~ '^[0-9]{13}$'),
  CONSTRAINT "chk_libro_titulo" CHECK (btrim("titulo") <> ''),
  CONSTRAINT "chk_libro_ano" CHECK ("ano_publicacion" BETWEEN 1450 AND 2100)
);

CREATE TABLE "LIBRO_AUTOR" (
  "ISBN" varchar,
  "id_autor" varchar,
  PRIMARY KEY ("ISBN", "id_autor")
);

CREATE TABLE "EJEMPLAR" (
  "ISBN" varchar,
  "num_ejemplar" varchar,
  "estado" varchar NOT NULL,
  "ubicacion" varchar,
  PRIMARY KEY ("ISBN", "num_ejemplar")
);

CREATE TABLE "USUARIO" (
  "id_usuario" varchar PRIMARY KEY,
  "id_rol" varchar NOT NULL,
  "nombre" varchar NOT NULL,
  "correo" varchar UNIQUE NOT NULL,
  "telefono" varchar,
  "contrasena" varchar NOT NULL
);

CREATE TABLE "PRESTAMO" (
  "id_prestamo" varchar PRIMARY KEY,
  "ISBN" varchar NOT NULL,
  "num_ejemplar" varchar NOT NULL,
  "id_usuario" varchar NOT NULL,
  "fecha_prestamo" date NOT NULL,
  "fecha_pactada" date NOT NULL,
  "fecha_real" date,
  "estado_mora" varchar
);

CREATE TABLE "ROL" (
  "id_rol" varchar PRIMARY KEY,
  "nombre_rol" varchar UNIQUE NOT NULL
);

ALTER TABLE "LIBRO" ADD FOREIGN KEY ("id_categoria") REFERENCES "CATEGORIA" ("id_categoria") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "USUARIO" ADD FOREIGN KEY ("id_rol") REFERENCES "ROL" ("id_rol") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "LIBRO_AUTOR" ADD FOREIGN KEY ("ISBN") REFERENCES "LIBRO" ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "LIBRO_AUTOR" ADD FOREIGN KEY ("id_autor") REFERENCES "AUTOR" ("id_autor") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "EJEMPLAR" ADD FOREIGN KEY ("ISBN") REFERENCES "LIBRO" ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "PRESTAMO" ADD FOREIGN KEY ("id_usuario") REFERENCES "USUARIO" ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "PRESTAMO" ADD FOREIGN KEY ("ISBN", "num_ejemplar") REFERENCES "EJEMPLAR" ("ISBN", "num_ejemplar") DEFERRABLE INITIALLY IMMEDIATE;
