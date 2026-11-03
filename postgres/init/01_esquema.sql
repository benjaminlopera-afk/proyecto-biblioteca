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
  PRIMARY KEY ("ISBN", "num_ejemplar")
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
  "fecha_prestamo" date NOT NULL,
  "fecha_pactada" date NOT NULL,
  "fecha_real" date,
  "estado_mora" varchar
);


-- Corregidas las referencias a mminusculas en el esquema 
ALTER TABLE libro ADD FOREIGN KEY ("id_categoria") REFERENCES biblioteca.categoria ("id_categoria") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE usuario ADD FOREIGN KEY ("id_rol") REFERENCES biblioteca.rol ("id_rol") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE libro_autor ADD FOREIGN KEY ("ISBN") REFERENCES biblioteca.libro ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE libro_autor ADD FOREIGN KEY ("id_autor") REFERENCES biblioteca.autor ("id_autor") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE ejemplar ADD FOREIGN KEY ("ISBN") REFERENCES biblioteca.libro ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("id_usuario") REFERENCES biblioteca.usuario ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("ISBN", "num_ejemplar") REFERENCES biblioteca.ejemplar ("ISBN", "num_ejemplar") DEFERRABLE INITIALLY IMMEDIATE;
