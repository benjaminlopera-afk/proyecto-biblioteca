-- -----------------------------------------------------------------------------
-- CASO 1: GIMNASIO
-- -----------------------------------------------------------------------------
/*
(a) Diagnostico: Se detectaron tres problemas para el esquema original del gimnasio y basado en la queja presentada.
 - problema 1: las clases no se encuentran normalizadas, no se respeta el principio de atomicidad por tal cosa incumple 
 la Primera Forma Normal.

 - problema 2: presentan inconsistencia en los nombres, 'Yoga' y 'yoga' se refieren a la misma clase y sin embargo se encuentran
 escritos de distinta forma, una busqueda textual resulta compleja con estas caracteristicas.

 - problema 3: Dependencia funcional del valor del plan, genera redundancia expresar un valor relacionado de plan -> valor_plan en la misma tabla.
 La dependencia transitiva entre id_socio -> plan -> valor_plan incumple la Tercera Forma Normal.
*/

/*
(b) Evidencia
*/

-- Query de queja: query aproximado que se uso para el caso de la queja
SET search_path TO gimnasio;

SELECT COUNT(DISTINCT id_socio) AS cantidad_socios
FROM socio
WHERE clases LIKE '%Yoga%';

SELECT COUNT(DISTINCT id_socio) AS cantidad_socios
FROM socio
WHERE clases LIKE '%Spinning%';

-- Query de existencia: se demuestra que los valores si existen pero estan en un formato incorrecto 
SELECT
    CASE
        WHEN LOWER(TRIM(x.nombre_clase)) = 'yoga'
            THEN 'Yoga'
        WHEN LOWER(TRIM(x.nombre_clase)) = 'spinning'
            THEN 'Spinning'
        WHEN LOWER(TRIM(x.nombre_clase)) = 'spinning avanzado'
            THEN 'Spinning avanzado'
        ELSE INITCAP(TRIM(x.nombre_clase))
    END AS nombre_clase,
    COUNT(DISTINCT s.id_socio) AS cantidad_socios
FROM gimnasio.socio s,
LATERAL UNNEST(
    STRING_TO_ARRAY(s.clases, ';')
) AS x(nombre_clase)
WHERE s.clases IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- Query de plan y valor_plan: Se evidencia que el precio se repite en los socios aunque dependa del plan
SELECT
    plan,
    COUNT(*) AS cantidad_socios,
    COUNT(DISTINCT valor_plan) AS valores_diferentes
FROM socio
GROUP BY plan;

/* 
(c) Correccion del esquema original: 
Se opto por crear las tablas plan, clase y la relacion socio clase para separar adecuadamente los valores.
*/


SET search_path TO gimnasio;

-- Tabla de planes
CREATE TABLE plan (
    nombre_plan VARCHAR(20) PRIMARY KEY,
    valor_plan INTEGER NOT NULL
);

-- Tabla de socios
CREATE TABLE socio (
    id_socio INTEGER PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL,
    nombre_plan VARCHAR(20) NOT NULL,

    FOREIGN KEY (nombre_plan)
        REFERENCES plan(nombre_plan)
);

-- Tabla de clases
CREATE TABLE clase (
    id_clase INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_clase VARCHAR(80) NOT NULL UNIQUE
);

-- Tabla intermedia: relación socios y clases
CREATE TABLE socio_clase (
    id_socio INTEGER NOT NULL,
    id_clase INTEGER NOT NULL,

    PRIMARY KEY (id_socio, id_clase),

    FOREIGN KEY (id_socio)
        REFERENCES socio(id_socio),

    FOREIGN KEY (id_clase)
        REFERENCES clase(id_clase)
);


/*
(d) Migracion
El siguiente script esta hecho para migrar los datos del esquema anterior hacia el nuevo esquema
*/


BEGIN;

SET search_path TO gimnasio;

-- 1. Conservar los datos originales
ALTER TABLE socio RENAME TO socio_legacy;


-- 2. Crear tabla de planes
CREATE TABLE plan (
    nombre_plan VARCHAR(20) PRIMARY KEY,
    valor_plan INTEGER NOT NULL
);


-- 3. Crear tabla de socios
CREATE TABLE socio (
    id_socio INTEGER PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL,
    nombre_plan VARCHAR(20) NOT NULL,

    FOREIGN KEY (nombre_plan)
        REFERENCES plan(nombre_plan)
);


-- 4. Crear tabla de clases
CREATE TABLE clase (
    id_clase INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_clase VARCHAR(80) NOT NULL UNIQUE
);


-- 5. Crear tabla intermedia de inscripciones
CREATE TABLE socio_clase (
    id_socio INTEGER NOT NULL,
    id_clase INTEGER NOT NULL,

    PRIMARY KEY (id_socio, id_clase),

    FOREIGN KEY (id_socio)
        REFERENCES socio(id_socio),

    FOREIGN KEY (id_clase)
        REFERENCES clase(id_clase)
);


-- 6. Crear tabla de horarios
CREATE TABLE horario_clase (
    id_horario INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_clase INTEGER NOT NULL,
    dia VARCHAR(15) NOT NULL,
    hora TIME NOT NULL,

    FOREIGN KEY (id_clase)
        REFERENCES clase(id_clase),

    UNIQUE (id_clase, dia, hora)
);


-- 7. Migrar los planes
INSERT INTO plan (nombre_plan, valor_plan)
SELECT DISTINCT plan, valor_plan
FROM socio_legacy;


-- 8. Migrar los socios
INSERT INTO socio (id_socio, nombre, nombre_plan)
SELECT id_socio, nombre, plan
FROM socio_legacy;


-- 9. Extraer las clases y normalizar sus nombres
INSERT INTO clase (nombre_clase)
SELECT DISTINCT
    CASE LOWER(TRIM(x.nombre_original))
        WHEN 'yoga' THEN 'Yoga'
        WHEN 'spinning' THEN 'Spinning'
        WHEN 'spinning avanzado' THEN 'Spinning avanzado'
        WHEN 'pilates' THEN 'Pilates'
        WHEN 'funcional' THEN 'Funcional'
    END
FROM socio_legacy s,
LATERAL UNNEST(
    STRING_TO_ARRAY(COALESCE(s.clases, ''), ';')
) AS x(nombre_original)
WHERE TRIM(x.nombre_original) <> '';


-- 10. Migrar las inscripciones
INSERT INTO socio_clase (id_socio, id_clase)
SELECT DISTINCT
    s.id_socio,
    c.id_clase
FROM socio_legacy s,
LATERAL UNNEST(
    STRING_TO_ARRAY(COALESCE(s.clases, ''), ';')
) AS x(nombre_original)
JOIN clase c
    ON c.nombre_clase =
       CASE LOWER(TRIM(x.nombre_original))
           WHEN 'yoga' THEN 'Yoga'
           WHEN 'spinning' THEN 'Spinning'
           WHEN 'spinning avanzado' THEN 'Spinning avanzado'
           WHEN 'pilates' THEN 'Pilates'
           WHEN 'funcional' THEN 'Funcional'
       END
WHERE TRIM(x.nombre_original) <> '';


COMMIT;

/*
(e) Verificacion
*/

-- Bloque de codigo para contar la aparicion de las clases en socio_clases
SELECT
    c.nombre_clase,
    COUNT(sc.id_socio) AS cantidad_socios
FROM gimnasio.clase c
LEFT JOIN gimnasio.socio_clase sc
    ON c.id_clase = sc.id_clase
GROUP BY c.id_clase, c.nombre_clase
ORDER BY c.nombre_clase;

/*
(f) Pregunta propia:
Despues de migrar, en que tabla deberia almacenarse la dificultad de cada clase (principiante, medio, avanzado) ?
R: La dificultad debe guardarse en la tabla clase ya que es la tabla que define los atributos de las clases si se requiere una clase con un mismo nombre
pero varias dificultades para ofrecer variedad habria que modificar el esquema para que PK (nombre_clase, dificultad_clase), de este modo no hay dos clases
del mismo nombre y dificultad*/

-- -----------------------------------------------------------------------------
-- CASO 2: FARMACIA
-- -----------------------------------------------------------------------------
SET search_path TO farmacia, public;

/*
(a) DIAGNÓSTICO:
1. Problema principal (explica la queja) - Violación de 1FN por grupos repetidos:
   - Las columnas (medicamento1, dosis1, medicamento2, dosis2, medicamento3, dosis3)
     constituyen un grupo repetido en paralelo. Impiden registrar una fórmula con 4 o más
     medicamentos, dejan múltiples columnas en NULL, obligan a consultar 3 columnas con OR
     para buscar un medicamento y no impiden repetir el mismo fármaco en una fórmula.
2. Problema secundario - Violación de 3FN (dependencia transitiva):
   - Clave candidata de `formula`: {num_formula}.
   - Dependencias funcionales:
       num_formula -> fecha, doc_paciente, nombre_paciente
       doc_paciente -> nombre_paciente
   - En `doc_paciente -> nombre_paciente`, `doc_paciente` NO es superclave y
     `nombre_paciente` NO es primo (dependencia transitiva num_formula -> doc_paciente -> nombre_paciente).
     El nombre 'Rosa Díaz' se repite en las fórmulas 701 y 703.
*/

-- (b) EVIDENCIA EN SQL:
-- 1. Evidencia de grupos repetidos, columnas en NULL y consulta compleja por 3 columnas:
SELECT count(*) AS formulas_con_acetaminofen
FROM farmacia.formula WHERE medicamento1 = 'Acetaminofén 500 mg'
   OR medicamento2 = 'Acetaminofén 500 mg'
   OR medicamento3 = 'Acetaminofén 500 mg';
-- Resultado esperado: 3

-- 2. Evidencia de redundancia en doc_paciente -> nombre_paciente:
SELECT doc_paciente, nombre_paciente, count(*) AS total_formulas
FROM farmacia.formula
GROUP BY doc_paciente, nombre_paciente
HAVING count(*) > 1;
-- Resultado esperado: 1110000111 | Rosa Díaz | 2

-- Verificar que no haya contradicciones en doc_paciente -> nombre_paciente (0 filas):
SELECT doc_paciente FROM farmacia.formula
GROUP BY doc_paciente
HAVING count(DISTINCT nombre_paciente) > 1;

-- (c) ESQUEMA CORREGIDO (3FN / FNBC) Y (d) MIGRACIÓN SEGURA:
BEGIN;

ALTER TABLE farmacia.formula RENAME TO formula_vieja;

CREATE TABLE farmacia.paciente (
    doc_paciente    varchar(15) PRIMARY KEY,
    nombre_paciente varchar(80) NOT NULL
);

CREATE TABLE farmacia.formula (
    num_formula  integer     PRIMARY KEY,
    fecha        date        NOT NULL,
    doc_paciente varchar(15) NOT NULL REFERENCES farmacia.paciente(doc_paciente)
);

CREATE TABLE farmacia.detalle_formula (
    num_formula integer     NOT NULL REFERENCES farmacia.formula(num_formula) ON DELETE CASCADE,
    medicamento varchar(60) NOT NULL,
    dosis       varchar(40) NOT NULL,
    PRIMARY KEY (num_formula, medicamento)
);

INSERT INTO farmacia.paciente (doc_paciente, nombre_paciente)
SELECT DISTINCT doc_paciente, nombre_paciente
FROM farmacia.formula_vieja;

INSERT INTO farmacia.formula (num_formula, fecha, doc_paciente)
SELECT num_formula, fecha, doc_paciente
FROM farmacia.formula_vieja;

INSERT INTO farmacia.detalle_formula (num_formula, medicamento, dosis)
SELECT num_formula, medicamento1, dosis1 FROM farmacia.formula_vieja WHERE medicamento1 IS NOT NULL
UNION ALL
SELECT num_formula, medicamento2, dosis2 FROM farmacia.formula_vieja WHERE medicamento2 IS NOT NULL
UNION ALL
SELECT num_formula, medicamento3, dosis3 FROM farmacia.formula_vieja WHERE medicamento3 IS NOT NULL;

-- (e) VERIFICACIÓN:
-- Conteos esperados: paciente = 3 | formula = 4 | detalle_formula = 8
SELECT 'paciente' AS tabla, count(*) AS obtenidos, 3 AS esperados FROM farmacia.paciente
UNION ALL SELECT 'formula',         count(*), 4 FROM farmacia.formula
UNION ALL SELECT 'detalle_formula', count(*), 8 FROM farmacia.detalle_formula;

-- Consulta de la queja resuelta (búsqueda en una sola columna):
SELECT count(*) AS formulas_con_acetaminofen
FROM farmacia.detalle_formula
WHERE medicamento = 'Acetaminofén 500 mg';
-- Resultado esperado: 3

DROP TABLE farmacia.formula_vieja;

COMMIT;

/*
PREGUNTA PROPIA (Caso 2):
¿Por qué no basta con agregar `medicamento4` y `dosis4`? Dar al menos dos razones.
1. Sigue existiendo un límite ya que en cuanto un paciente necesite 5 o más medicamentos,
   el sistema volverá a fallar y exigirá modificar el esquema (ALTER TABLE) y el código.
2. Las consultas y reportes siguen siendo complejos e ineficientes: buscar, contar o cruzar
   medicamentos obliga a escribir condiciones repetitivas sobre 4 columnas (OR / UNION).
3. no se puede definir una clave primaria o UNIQUE que impida recetar el mismo medicamento 
   dos veces en la misma fórmula,ni poner una sola FK hacia un catálogo de medicamentos.
*/


-- =============================================================================
-- Mapa del archivo
--   (a) Diagnóstico            (comentarios)
--   (b) Evidencia              (consultas)
--   (c) Esquema corregido      (comentarios)
--   (d) Migración              (BEGIN ... COMMIT)
--   (e) Verificación           (dentro de la transacción, antes de borrar lo viejo)
--   Pregunta propia            (comentarios, al final)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CASO 3: CURSOS
-- -----------------------------------------------------------------------------

SET search_path TO cursos_libres;


-- =============================================================================
-- (a) DIAGNÓSTICO
-- =============================================================================
-- Dependencias funcionales:
--   1. cod_curso -> nombre_curso, cod_sede      "cada curso se dicta en una sola sede"
--   2. cod_sede  -> direccion_sede              una sede tiene una dirección
--   3. doc_participante -> nombre_participante, correo
--   4. correo -> doc_participante, nombre_participante
--                                               "el correo identifica a un participante"
--   5. doc_participante, cod_curso -> valor_pagado
--                                               "se inscribe a lo sumo una vez en cada curso"
--   (por 4 y 5 también: correo, cod_curso -> valor_pagado)
--
-- Claves candidatas de inscripcion:
--   id, (doc_participante, cod_curso), (correo, cod_curso)
--   Solo la primera está declarada. Atributos primos: id, doc_participante,
--   correo, cod_curso. No primos: nombre_participante, nombre_curso, cod_sede,
--   direccion_sede, valor_pagado.
--
-- Problema principal: falta la restricción UNIQUE sobre la
--   clave natural (doc_participante, cod_curso). Con id serial como única clave,
--   la misma inscripción se puede insertar dos veces, y su valor_pagado se
--   suma dos veces en el recaudo.
--
-- Problemas secundarios:
--   * 2FN no se cumple: cod_curso -> nombre_curso, cod_sede depende de una parte
--     de la clave candidata (doc_participante, cod_curso); doc_participante ->
--     nombre_participante, correo, de la otra parte. Que la PK sea de una sola
--     columna no cambia esto: las formas normales miran todas las claves candidatas.
--   * 3FN tampoco: cod_sede -> direccion_sede es transitiva (cod_curso -> cod_sede
--     -> direccion_sede); cod_sede no es superclave y direccion_sede no es primo.
--   * Forma normal más alta: 1FN (los valores son atómicos).
--   * Redundancia: nombre y correo del participante se repiten en cada curso
--     que toma; nombre del curso y dirección de la sede, en cada inscripción.


-- =============================================================================
-- (b) EVIDENCIA
-- =============================================================================

-- b1. La queja: inscripciones repetidas para el mismo participante y curso.
SELECT doc_participante, cod_curso,
       count(*)                          AS veces,
       array_agg(id ORDER BY id)         AS ids,
       array_agg(valor_pagado ORDER BY id) AS valores
FROM inscripcion
GROUP BY doc_participante, cod_curso
HAVING count(*) > 1;

-- b2. Cuánto recaudo sobra por curso. Se numeran las inscripciones repetidas
--     y todo lo que pase de la primera es "sobrante".
WITH numeradas AS (
    SELECT *, row_number() OVER (PARTITION BY doc_participante, cod_curso ORDER BY id) AS rn
    FROM inscripcion
)
SELECT cod_curso,
       min(nombre_curso)                                  AS nombre_curso,
       sum(valor_pagado)                                  AS recaudo_segun_tabla,
       sum(valor_pagado) FILTER (WHERE rn = 1)            AS recaudo_sin_repetidas,
       coalesce(sum(valor_pagado) FILTER (WHERE rn > 1), 0) AS sobrante
FROM numeradas
GROUP BY cod_curso
ORDER BY sobrante DESC, cod_curso;

-- b3. Auditoría de las dependencias: cuántos valores del determinante aparecen
--     con más de un valor dependiente. Lo esperado es 0 en todas. Si alguna da
--     más de 0, hay que decidir cuál es el dato correcto ANTES de migrar y
--     corregirlo con un UPDATE justificado (ver el punto 1 de la sección 4 de S19).
CREATE OR REPLACE TEMP VIEW auditoria_c3 AS
SELECT 1 AS n, 'cod_curso -> nombre_curso, cod_sede' AS dependencia,
       (SELECT count(*) FROM (SELECT cod_curso FROM inscripcion
            GROUP BY cod_curso
            HAVING count(DISTINCT (nombre_curso, cod_sede)) > 1) t) AS contradicciones
UNION ALL
SELECT 2, 'cod_sede -> direccion_sede',
       (SELECT count(*) FROM (SELECT cod_sede FROM inscripcion
            GROUP BY cod_sede
            HAVING count(DISTINCT direccion_sede) > 1) t)
UNION ALL
SELECT 3, 'doc_participante -> nombre_participante, correo',
       (SELECT count(*) FROM (SELECT doc_participante FROM inscripcion
            GROUP BY doc_participante
            HAVING count(DISTINCT (nombre_participante, correo)) > 1) t)
UNION ALL
SELECT 4, 'correo -> doc_participante, nombre_participante',
       (SELECT count(*) FROM (SELECT correo FROM inscripcion
            GROUP BY correo
            HAVING count(DISTINCT (doc_participante, nombre_participante)) > 1) t)
UNION ALL
SELECT 5, 'doc_participante, cod_curso -> valor_pagado (repetidas con valores distintos)',
       (SELECT count(*) FROM (SELECT doc_participante, cod_curso FROM inscripcion
            GROUP BY doc_participante, cod_curso
            HAVING count(DISTINCT valor_pagado) > 1) t);

SELECT n, dependencia, contradicciones,
       CASE WHEN contradicciones = 0 THEN 'se cumple' ELSE 'SE VIOLA' END AS estado
FROM auditoria_c3
ORDER BY n;

-- b4. Redundancia: cuántas veces se repite cada curso con su sede.
SELECT cod_curso, nombre_curso, cod_sede, direccion_sede, count(*) AS filas
FROM inscripcion
GROUP BY cod_curso, nombre_curso, cod_sede, direccion_sede
ORDER BY filas DESC, cod_curso;


-- =============================================================================
-- (c) ESQUEMA CORREGIDO
-- =============================================================================
--   sede         (cod_sede PK, direccion_sede)
--   curso        (cod_curso PK, nombre_curso, cod_sede -> sede)
--   participante (doc_participante PK, nombre_participante, correo UNIQUE)
--   inscripcion  (doc_participante -> participante, cod_curso -> curso,
--                 valor_pagado)                  PK (doc_participante, cod_curso)
--
-- Se elimina el id: la clave natural (doc_participante, cod_curso) ya identifica
-- cada inscripción, y ahora la protege la PK. El correo queda UNIQUE porque
-- identifica a un participante (regla del enunciado).


-- =============================================================================
-- (d) MIGRACIÓN
-- =============================================================================

-- Conteos esperados, calculados ANTES de tocar nada (valores distintos de cada
-- clave en la tabla original, que tiene 8 filas):
--   sedes = 2 , cursos = 3 , participantes = 4 , inscripciones = 7
--   (8 filas - 1 repetida = 7: Juliana Rey en Fotografía digital, ids 3 y 7)
CREATE TEMP TABLE esperados AS
SELECT (SELECT count(DISTINCT cod_sede)                       FROM inscripcion) AS sedes,
       (SELECT count(DISTINCT cod_curso)                      FROM inscripcion) AS cursos,
       (SELECT count(DISTINCT doc_participante)               FROM inscripcion) AS participantes,
       (SELECT count(DISTINCT (doc_participante, cod_curso))  FROM inscripcion) AS inscripciones,
       (SELECT count(*)                                       FROM inscripcion) AS filas_viejas;

SELECT * FROM esperados;

BEGIN;

-- Guardia: no se migra si los datos contradicen alguna dependencia.
-- (Si falla, la transacción queda abortada: no se cambia nada.)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM auditoria_c3 WHERE contradicciones > 0) THEN
        RAISE EXCEPTION 'Hay datos que contradicen una dependencia: revisar auditoria_c3 y corregir antes de migrar';
    END IF;
END $$;

-- La tabla vieja se conserva con otro nombre hasta verificar.
ALTER TABLE inscripcion RENAME TO inscripcion_vieja;

CREATE TABLE sede (
    cod_sede        char(2)      NOT NULL,
    direccion_sede  varchar(60)  NOT NULL,
    CONSTRAINT pk_sede PRIMARY KEY (cod_sede)
);

CREATE TABLE curso (
    cod_curso     char(3)      NOT NULL,
    nombre_curso  varchar(60)  NOT NULL,
    cod_sede      char(2)      NOT NULL,
    CONSTRAINT pk_curso      PRIMARY KEY (cod_curso),
    CONSTRAINT fk_curso_sede FOREIGN KEY (cod_sede) REFERENCES sede (cod_sede)
);

CREATE TABLE participante (
    doc_participante     varchar(15) NOT NULL,
    nombre_participante  varchar(80) NOT NULL,
    correo               varchar(120) NOT NULL,
    CONSTRAINT pk_participante        PRIMARY KEY (doc_participante),
    CONSTRAINT uq_participante_correo UNIQUE (correo)
);

CREATE TABLE inscripcion (
    doc_participante  varchar(15) NOT NULL,
    cod_curso         char(3)     NOT NULL,
    valor_pagado      integer     NOT NULL,
    CONSTRAINT pk_inscripcion              PRIMARY KEY (doc_participante, cod_curso),
    CONSTRAINT fk_inscripcion_participante FOREIGN KEY (doc_participante) REFERENCES participante (doc_participante),
    CONSTRAINT fk_inscripcion_curso        FOREIGN KEY (cod_curso)        REFERENCES curso (cod_curso),
    CONSTRAINT ck_inscripcion_valor        CHECK (valor_pagado >= 0)
);

-- Copia, en el orden que respeta las FK.
INSERT INTO sede (cod_sede, direccion_sede)
SELECT DISTINCT cod_sede, direccion_sede FROM inscripcion_vieja;

INSERT INTO curso (cod_curso, nombre_curso, cod_sede)
SELECT DISTINCT cod_curso, nombre_curso, cod_sede FROM inscripcion_vieja;

INSERT INTO participante (doc_participante, nombre_participante, correo)
SELECT DISTINCT doc_participante, nombre_participante, correo FROM inscripcion_vieja;

-- Las inscripciones repetidas (misma persona y mismo curso) son copias del mismo
-- hecho: se conserva una, la de menor id. La guardia de la auditoría (punto 5)
-- ya garantizó que las repetidas tienen el mismo valor_pagado; si no, no se llega aquí.
INSERT INTO inscripcion (doc_participante, cod_curso, valor_pagado)
SELECT DISTINCT ON (doc_participante, cod_curso)
       doc_participante, cod_curso, valor_pagado
FROM inscripcion_vieja
ORDER BY doc_participante, cod_curso, id;


-- =============================================================================
-- (e) VERIFICACIÓN
-- =============================================================================

-- e1. Conteos obtenidos frente a esperados.
SELECT tabla, obtenidas, esperadas, obtenidas = esperadas AS coincide
FROM (VALUES
    ('sede',         (SELECT count(*) FROM sede),         (SELECT sedes         FROM esperados)),
    ('curso',        (SELECT count(*) FROM curso),        (SELECT cursos        FROM esperados)),
    ('participante', (SELECT count(*) FROM participante), (SELECT participantes FROM esperados)),
    ('inscripcion',  (SELECT count(*) FROM inscripcion),  (SELECT inscripciones FROM esperados))
) AS t(tabla, obtenidas, esperadas);

-- e2. Reconstrucción con joins y EXCEPT en los dos sentidos (sin id).
--     EXCEPT trabaja con conjuntos, así que las repetidas colapsan en una.
--     Esperado: 0 y 0.
CREATE TEMP VIEW reconstruida_c3 AS
SELECT i.doc_participante, p.nombre_participante, p.correo,
       i.cod_curso, c.nombre_curso, c.cod_sede, s.direccion_sede, i.valor_pagado
FROM inscripcion i
JOIN participante p ON p.doc_participante = i.doc_participante
JOIN curso        c ON c.cod_curso        = i.cod_curso
JOIN sede         s ON s.cod_sede         = c.cod_sede;

SELECT 'inscripcion_vieja EXCEPT reconstruida (se perdió algo)' AS prueba, count(*) AS filas
FROM (SELECT doc_participante, nombre_participante, correo, cod_curso, nombre_curso,
             cod_sede, direccion_sede, valor_pagado FROM inscripcion_vieja
      EXCEPT
      SELECT * FROM reconstruida_c3) t
UNION ALL
SELECT 'reconstruida EXCEPT inscripcion_vieja (se inventó algo)', count(*)
FROM (SELECT * FROM reconstruida_c3
      EXCEPT
      SELECT doc_participante, nombre_participante, correo, cod_curso, nombre_curso,
             cod_sede, direccion_sede, valor_pagado FROM inscripcion_vieja) t;

-- e3. Filas que se quitaron: deben ser exactamente las repetidas.
SELECT (SELECT filas_viejas FROM esperados)   AS filas_viejas,
       (SELECT count(*) FROM inscripcion)     AS filas_nuevas,
       (SELECT filas_viejas FROM esperados) - (SELECT count(*) FROM inscripcion) AS repetidas_quitadas;

-- e4. La queja resuelta: recaudo por curso antes y después. La diferencia es el
--     dinero de las inscripciones repetidas.
SELECT c.cod_curso,
       c.nombre_curso,
       v.recaudo_viejo,
       n.recaudo_nuevo,
       v.recaudo_viejo - n.recaudo_nuevo AS diferencia
FROM curso c
JOIN (SELECT cod_curso, sum(valor_pagado) AS recaudo_viejo FROM inscripcion_vieja GROUP BY cod_curso) v
     ON v.cod_curso = c.cod_curso
JOIN (SELECT cod_curso, sum(valor_pagado) AS recaudo_nuevo FROM inscripcion       GROUP BY cod_curso) n
     ON n.cod_curso = c.cod_curso
ORDER BY diferencia DESC, c.cod_curso;

-- e5. Guardia final: si los conteos no coinciden, no se continúa.
DO $$
DECLARE e esperados%ROWTYPE;
BEGIN
    SELECT * INTO e FROM esperados;
    IF (SELECT count(*) FROM sede)         <> e.sedes
    OR (SELECT count(*) FROM curso)        <> e.cursos
    OR (SELECT count(*) FROM participante) <> e.participantes
    OR (SELECT count(*) FROM inscripcion)  <> e.inscripciones THEN
        RAISE EXCEPTION 'Los conteos no coinciden con los esperados: no se borra la tabla vieja';
    END IF;
END $$;

-- Solo después de verificar se quita lo viejo. La vista de auditoría se borra
-- primero: sigue a la tabla renombrada y no dejaría borrarla.
DROP VIEW auditoria_c3;
DROP TABLE inscripcion_vieja;

COMMIT;

-- e6. Ya en el esquema nuevo, con la tabla vieja borrada: la queja de Contabilidad.
--     Cambiar el filtro por el nombre exacto del curso si se quiere.
SELECT c.nombre_curso, count(*) AS inscripciones, sum(i.valor_pagado) AS recaudo
FROM inscripcion i
JOIN curso c ON c.cod_curso = i.cod_curso
WHERE c.nombre_curso ILIKE '%fotograf%'
GROUP BY c.nombre_curso;


-- =============================================================================
-- PREGUNTA PROPIA
-- "La tabla tiene una PK de una sola columna. ¿Por qué eso no la pone en 2FN?
--  ¿Qué restricción le faltaba al diseño original, y qué habría evitado?"
--
-- Una PK de una columna no pone una tabla en 2FN porque la definición se aplica
-- a TODAS las claves candidatas, no solo a la PK declarada. Aquí (doc_participante,
-- cod_curso) identifica una inscripción (regla: a lo sumo una vez por curso) y
-- (correo, cod_curso) también (el correo identifica al participante). Son
-- candidatas aunque nadie las declaró, y de ellas dependen en parte
-- nombre_curso, cod_sede, nombre_participante y correo. Agregar un id solo
-- cambió el nombre de la PK, no las dependencias.
--
-- Le faltaba UNIQUE (doc_participante, cod_curso) sobre la clave natural
-- (y UNIQUE sobre el correo). Con esa restricción, el segundo INSERT de la
-- misma inscripción habría sido rechazado, y Contabilidad no tendría 200 000
-- pesos de más: el error se habría detectado al registrarlo, no al cuadrar caja.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- CASO 4: ENVIOS
-- -----------------------------------------------------------------------------

-- =============================================================================
-- Mapa del archivo
--   (a) Diagnóstico            (comentarios)
--   (b) Evidencia              (consultas)
--   (c) Esquema corregido      (comentarios)
--   (d) Migración              (BEGIN ... COMMIT)
--   (e) Verificación           (dentro de la transacción, antes de borrar lo viejo)
--   Pregunta propia            (respuesta y demostración)
-- =============================================================================

SET search_path TO envios;


-- =============================================================================
-- (a) DIAGNÓSTICO
-- =============================================================================
-- Dependencias funcionales (reglas del enunciado):
--   1. num_guia -> fecha, ciudad_destino, peso_kg, valor
--                          (cada fila es un envío)
--   2. ciudad_destino -> departamento, zona
--                          "cada ciudad pertenece a un departamento y a una zona"
--   3. zona -> tarifa_kg
--                          "cada zona tiene una tarifa por kilo"
--   4. peso_kg, tarifa_kg -> valor
--                          "el valor de un envío es el peso por la tarifa"
--
-- Clave candidata: solo num_guia. Atributos primos: num_guia; todos los demás
-- son no primos.
--
-- Forma normal más alta: 2FN. Con una clave de un solo atributo no hay
-- dependencias parciales, pero 3FN se incumple:
--   * ciudad_destino -> departamento, zona: ciudad_destino no es superclave y
--     departamento y zona no son primos.
--   * zona -> tarifa_kg: transitiva (num_guia -> ciudad_destino -> zona -> tarifa_kg).
--   * peso_kg, tarifa_kg -> valor: el determinante tampoco es superclave.
--
-- Problema principal: valor es un DATO DERIVADO guardado.
--   Debería ser peso_kg * tarifa_kg, pero nada obliga a que lo sea: se
--   digitó a mano y puede quedar mal. Es la señal "columna calculable".
--
-- Problemas secundarios: departamento, zona y tarifa_kg se repiten en cada
--   envío a la misma ciudad (redundancia que permite contradicciones).


-- =============================================================================
-- (b) EVIDENCIA
-- =============================================================================

-- b1. La queja: envíos cuyo valor no es peso × tarifa.
SELECT num_guia, fecha, ciudad_destino, zona, tarifa_kg, peso_kg,
       valor                          AS valor_cobrado,
       peso_kg * tarifa_kg            AS valor_segun_regla,
       valor - peso_kg * tarifa_kg    AS cobrado_de_mas
FROM envio
WHERE valor <> peso_kg * tarifa_kg;

-- b2. Los envíos a Bogotá, para ver qué pasó con el cliente que reclama.
SELECT num_guia, fecha, peso_kg, tarifa_kg, valor,
       peso_kg * tarifa_kg AS valor_segun_regla
FROM envio
WHERE ciudad_destino = 'Bogotá'
ORDER BY fecha;

-- b3. Auditoría. Las filas 1 y 2 son dependencias: cuántos valores del
--     determinante aparecen con más de un valor dependiente (esperado: 0).
--     La fila 3 es el dato derivado: cuántos envíos no cumplen peso × tarifa.
CREATE OR REPLACE TEMP VIEW auditoria_c4 AS
SELECT 1 AS n, 'ciudad_destino -> departamento, zona' AS regla,
       (SELECT count(*) FROM (SELECT ciudad_destino FROM envio
            GROUP BY ciudad_destino
            HAVING count(DISTINCT (departamento, zona)) > 1) t) AS contradicciones
UNION ALL
SELECT 2, 'zona -> tarifa_kg',
       (SELECT count(*) FROM (SELECT zona FROM envio
            GROUP BY zona
            HAVING count(DISTINCT tarifa_kg) > 1) t)
UNION ALL
SELECT 3, 'valor = peso_kg * tarifa_kg (dato derivado)',
       (SELECT count(*) FROM envio WHERE valor <> peso_kg * tarifa_kg);

SELECT n, regla, contradicciones,
       CASE WHEN contradicciones = 0 THEN 'se cumple' ELSE 'SE VIOLA' END AS estado
FROM auditoria_c4
ORDER BY n;

-- b4. Redundancia: cuántas veces se repite cada ciudad con su departamento,
--     zona y tarifa.
SELECT ciudad_destino, departamento, zona, tarifa_kg, count(*) AS envios
FROM envio
GROUP BY ciudad_destino, departamento, zona, tarifa_kg
ORDER BY envios DESC, ciudad_destino;


-- =============================================================================
-- (c) ESQUEMA CORREGIDO
-- =============================================================================
--   zona   (zona PK, tarifa_kg)
--   ciudad (ciudad_destino PK, departamento, zona -> zona)
--   envio  (num_guia PK, fecha, ciudad_destino -> ciudad, peso_kg, valor)
--
-- valor se queda en envio, pero ya no como "dato calculable" sino como el valor
-- COBRADO: un hecho histórico del envío (ver la pregunta propia). La tarifa
-- vigente vive solo en zona. Como valor ya no se puede deducir de las demás
-- tablas una vez que cambien las tarifas, no es redundancia.


-- =============================================================================
-- (d) MIGRACIÓN
-- =============================================================================

-- Conteos esperados, calculados ANTES de tocar nada (valores distintos de cada
-- clave en la tabla original, que tiene 8 filas):
--   zonas = 3 , ciudades = 5 , envios = 8
CREATE TEMP TABLE esperados AS
SELECT (SELECT count(DISTINCT zona)           FROM envio) AS zonas,
       (SELECT count(DISTINCT ciudad_destino) FROM envio) AS ciudades,
       (SELECT count(*)                       FROM envio) AS envios;

SELECT * FROM esperados;

BEGIN;

-- Guardia 1: las dependencias de las filas 1 y 2 deben cumplirse; si no, las
-- tablas nuevas no se pueden llenar sin elegir entre datos contradictorios.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM auditoria_c4 WHERE n <= 2 AND contradicciones > 0) THEN
        RAISE EXCEPTION 'Hay datos que contradicen una dependencia: revisar auditoria_c4 y corregir antes de migrar';
    END IF;
END $$;

-- Corrección del dato derivado. DECISIÓN: la regla del negocio dice que
-- valor = peso × tarifa. El envío G07 (Bogotá, zona 2, tarifa 6000, 4.0 kg)
-- debería valer 24 000 y figura en 42 000; el cliente reclama que le cobraron de
-- más, y eso coincide con el dato (18 000 de diferencia). Se corrige el valor y
-- se conserva el peso, suponiendo que el peso registrado es el correcto
-- (42 000 equivaldría a 7 kg, que no es lo que se pesó): conviene confirmarlo
-- con el registro de la báscula y devolverle al cliente la diferencia.
SELECT num_guia, peso_kg, tarifa_kg, valor AS valor_antes
FROM envio WHERE num_guia = 'G07';

UPDATE envio
SET    valor = round(peso_kg * tarifa_kg)::integer
WHERE  num_guia = 'G07'
  AND  valor <> peso_kg * tarifa_kg
RETURNING num_guia, peso_kg, tarifa_kg, valor AS valor_corregido;

-- Guardia 2: después de la corrección no debe quedar ningún envío inconsistente.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM auditoria_c4 WHERE contradicciones > 0) THEN
        RAISE EXCEPTION 'Quedan datos inconsistentes después de la corrección: revisar auditoria_c4';
    END IF;
END $$;

-- La tabla vieja se conserva con otro nombre hasta verificar.
ALTER TABLE envio RENAME TO envio_viejo;

CREATE TABLE zona (
    zona       smallint NOT NULL,
    tarifa_kg  integer  NOT NULL,
    CONSTRAINT pk_zona       PRIMARY KEY (zona),
    CONSTRAINT ck_zona_tarifa CHECK (tarifa_kg > 0)
);

CREATE TABLE ciudad (
    ciudad_destino  varchar(40) NOT NULL,
    departamento    varchar(40) NOT NULL,
    zona            smallint    NOT NULL,
    CONSTRAINT pk_ciudad      PRIMARY KEY (ciudad_destino),
    CONSTRAINT fk_ciudad_zona FOREIGN KEY (zona) REFERENCES zona (zona)
);

CREATE TABLE envio (
    num_guia        char(3)       NOT NULL,
    fecha           date          NOT NULL,
    ciudad_destino  varchar(40)   NOT NULL,
    peso_kg         numeric(5,1)  NOT NULL,
    valor           integer       NOT NULL,
    CONSTRAINT pk_envio        PRIMARY KEY (num_guia),
    CONSTRAINT fk_envio_ciudad FOREIGN KEY (ciudad_destino) REFERENCES ciudad (ciudad_destino),
    CONSTRAINT ck_envio_peso   CHECK (peso_kg > 0),
    CONSTRAINT ck_envio_valor  CHECK (valor >= 0)
);


INSERT INTO zona (zona, tarifa_kg)
SELECT DISTINCT zona, tarifa_kg FROM envio_viejo;

INSERT INTO ciudad (ciudad_destino, departamento, zona)
SELECT DISTINCT ciudad_destino, departamento, zona FROM envio_viejo;

INSERT INTO envio (num_guia, fecha, ciudad_destino, peso_kg, valor)
SELECT num_guia, fecha, ciudad_destino, peso_kg, valor FROM envio_viejo;


-- =============================================================================
-- (e) VERIFICACIÓN
-- =============================================================================

-- e1. Conteos obtenidos frente a esperados.
SELECT tabla, obtenidas, esperadas, obtenidas = esperadas AS coincide
FROM (VALUES
    ('zona',   (SELECT count(*) FROM zona),   (SELECT zonas    FROM esperados)),
    ('ciudad', (SELECT count(*) FROM ciudad), (SELECT ciudades FROM esperados)),
    ('envio',  (SELECT count(*) FROM envio),  (SELECT envios   FROM esperados))
) AS t(tabla, obtenidas, esperadas);

-- e2. Reconstrucción con joins y EXCEPT en los dos sentidos.
--     La tabla vieja ya lleva la corrección de G07. Esperado: 0 y 0.
CREATE TEMP VIEW reconstruida_c4 AS
SELECT e.num_guia, e.fecha, e.ciudad_destino, c.departamento, c.zona,
       z.tarifa_kg, e.peso_kg, e.valor
FROM envio e
JOIN ciudad c ON c.ciudad_destino = e.ciudad_destino
JOIN zona   z ON z.zona           = c.zona;

SELECT 'envio_viejo EXCEPT reconstruida (se perdió algo)' AS prueba, count(*) AS filas
FROM (SELECT num_guia, fecha, ciudad_destino, departamento, zona, tarifa_kg, peso_kg, valor
      FROM envio_viejo
      EXCEPT
      SELECT * FROM reconstruida_c4) t
UNION ALL
SELECT 'reconstruida EXCEPT envio_viejo (se inventó algo)', count(*)
FROM (SELECT * FROM reconstruida_c4
      EXCEPT
      SELECT num_guia, fecha, ciudad_destino, departamento, zona, tarifa_kg, peso_kg, valor
      FROM envio_viejo) t;

-- e3. La queja resuelta en el esquema nuevo: los envíos a Bogotá, con la
--     tarifa que sale de zona. La diferencia debe ser 0 en todos.
SELECT e.num_guia, e.fecha, e.peso_kg, z.tarifa_kg, e.valor,
       e.peso_kg * z.tarifa_kg         AS valor_segun_regla,
       e.valor - e.peso_kg * z.tarifa_kg AS diferencia
FROM envio e
JOIN ciudad c ON c.ciudad_destino = e.ciudad_destino
JOIN zona   z ON z.zona           = c.zona
WHERE e.ciudad_destino = 'Bogotá'
ORDER BY e.fecha;

-- e4. Y en general: ningún envío del esquema nuevo cobrado distinto a la regla.
--     Esperado: 0.
SELECT count(*) AS envios_inconsistentes
FROM envio e
JOIN ciudad c ON c.ciudad_destino = e.ciudad_destino
JOIN zona   z ON z.zona           = c.zona
WHERE e.valor <> e.peso_kg * z.tarifa_kg;

-- e5. Guardia final: si los conteos no coinciden, no se continúa.
DO $$
DECLARE e esperados%ROWTYPE;
BEGIN
    SELECT * INTO e FROM esperados;
    IF (SELECT count(*) FROM zona)   <> e.zonas
    OR (SELECT count(*) FROM ciudad) <> e.ciudades
    OR (SELECT count(*) FROM envio)  <> e.envios THEN
        RAISE EXCEPTION 'Los conteos no coinciden con los esperados: no se borra la tabla vieja';
    END IF;
END $$;

-- Solo después de verificar se quita lo viejo. La vista de auditoría se borra
-- primero: sigue a la tabla renombrada y no dejaría borrarla.
DROP VIEW auditoria_c4;
DROP TABLE envio_viejo;

COMMIT;


-- =============================================================================
-- PREGUNTA PROPIA
-- "La transportadora anuncia que en enero sube las tarifas. Con el esquema
--  corregido, ¿qué pasa con el valor de los envíos de octubre cuando se cambie la
--  tarifa de la zona? ¿Qué cambiarían en el diseño para que eso no pase, y eso es
--  redundancia o no?"
--
-- Qué pasa: si el valor se calculara siempre como peso_kg * zona.tarifa_kg (el
-- diseño "puro", con valor como vista), al subir la tarifa de la zona cambiaría
-- también el valor de los envíos de octubre: se reescribiría el pasado y los
-- registros de lo cobrado dejarían de coincidir con lo que se recaudó. Con la
-- tarifa de la zona hay una sola versión de la tarifa, la vigente.
--
-- Qué se cambia: guardar el valor cobrado en cada envío (como se hizo aquí:
-- envio.valor), o bien guardar las tarifas con su fecha de vigencia
-- (tarifa_zona(zona, vigente_desde, tarifa_kg), PK (zona, vigente_desde)) y
-- buscar la tarifa que regía en la fecha del envío. Cualquiera de las dos
-- conserva el pasado.
--
-- ¿Es redundancia? No. Redundancia es un dato que se puede deducir de los otros
-- datos de la base en todo momento. valor = peso × tarifa lo era mientras la
-- tarifa nunca cambiara. Cuando la tarifa cambia, el valor de octubre ya no se
-- puede deducir de lo que hay en zona (ahí solo está la tarifa de enero): es un
-- hecho histórico, lo que se cobró ese día. Se parece a un dato derivado, pero
-- es un dato registrado. Distinguirlos es la diferencia: derivado = se puede
-- recalcular siempre; histórico = depende del momento y se guarda.
--
-- Demostración (se deshace con ROLLBACK): se sube la tarifa de la zona 2 y se
-- compara lo que daría "valor calculado" con el valor guardado.
-- =============================================================================

BEGIN;

UPDATE zona SET tarifa_kg = 7000 WHERE zona = 2;   -- sube de 6000 a 7000 en enero

SELECT e.num_guia, e.fecha, e.peso_kg,
       e.valor                    AS valor_guardado_octubre,
       e.peso_kg * z.tarifa_kg    AS valor_si_fuera_calculado
FROM envio e
JOIN ciudad c ON c.ciudad_destino = e.ciudad_destino
JOIN zona   z ON z.zona           = c.zona
WHERE z.zona = 2
ORDER BY e.num_guia;

ROLLBACK;
