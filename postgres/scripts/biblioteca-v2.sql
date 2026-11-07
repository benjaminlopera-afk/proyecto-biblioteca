SET search_path TO biblioteca, public;

CREATE TABLE categoria (
  "id_categoria" varchar PRIMARY KEY,
  "nombre" varchar NOT NULL
);

CREATE TABLE autor (
  "id_autor" varchar PRIMARY KEY,
  "nombre" varchar NOT NULL,
  "nacionalidad" varchar
);

CREATE TABLE libro (
  "ISBN" varchar PRIMARY KEY,
  "id_categoria" varchar NOT NULL,
  "titulo" varchar NOT NULL,
  "editorial" varchar,
  "ano_publicacion" int
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

CREATE TABLE rol (
  "id_rol" varchar PRIMARY KEY,
  "nombre_rol" varchar UNIQUE NOT NULL
);

ALTER TABLE libro ADD FOREIGN KEY ("id_categoria") REFERENCES categoria ("id_categoria") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE usuario ADD FOREIGN KEY ("id_rol") REFERENCES rol ("id_rol") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE libro_autor ADD FOREIGN KEY ("ISBN") REFERENCES libro ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE libro_autor ADD FOREIGN KEY ("id_autor") REFERENCES autor ("id_autor") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE ejemplar ADD FOREIGN KEY ("ISBN") REFERENCES libro ("ISBN") ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("id_usuario") REFERENCES usuario ("id_usuario") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE prestamo ADD FOREIGN KEY ("ISBN", "num_ejemplar") REFERENCES ejemplar ("ISBN", "num_ejemplar") DEFERRABLE INITIALLY IMMEDIATE;
