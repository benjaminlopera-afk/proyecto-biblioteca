-- =====================================================================
-- S15-reportes-v2.sql
-- Reportes del proyecto adaptados al esquema real (biblioteca-v2).
--
-- Se basan en los 4 reportes de referencia S15-reportes-demo.sql,
-- re-escritos para usar el esquema actual del proyecto:
--   biblioteca.usuario, biblioteca.libro, biblioteca.prestamo
-- =====================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- este script solo contiene los 4 reportes.
-- ---------------------------------------------------------------------------

\echo
\echo '== Reporte 1. Los libros más prestados (primeros 3 con empates) =='
SELECT l.titulo,
       count(p.id_prestamo) AS prestamos
FROM   biblioteca.libro l
LEFT JOIN biblioteca.prestamo p
       ON p."ISBN" = l."ISBN"
GROUP BY l."ISBN", l.titulo
ORDER BY prestamos DESC, l.titulo
FETCH FIRST 3 ROWS WITH TIES;

\echo
\echo '== Reporte 2. El o los lectores que más libros han leído (préstamos devueltos) =='
WITH leidos AS (
    SELECT p.id_usuario, count(*) AS devueltos
    FROM   biblioteca.prestamo p
    WHERE  p.fecha_real IS NOT NULL
    GROUP BY p.id_usuario
)
SELECT u.id_usuario, u.nombre, u.correo, x.devueltos
FROM   leidos x
JOIN   biblioteca.usuario u
       ON u.id_usuario = x.id_usuario
WHERE  x.devueltos = (SELECT max(devueltos) FROM leidos)
ORDER BY u.nombre;

\echo
\echo '== Reporte 3. Lectores morosos =='
SELECT u.id_usuario,
       u.nombre,
       u.correo,
       u.telefono
FROM   biblioteca.usuario u
WHERE  EXISTS (
    SELECT 1
    FROM   biblioteca.vista_prestamo vp
    WHERE  vp.id_usuario = u.id_usuario
      AND  vp.fecha_real IS NULL
      AND  vp.estado_mora = 'Con mora'
)
ORDER BY u.nombre;

\echo
\echo '== Reporte 4. Préstamos en mora (para la lista de notificación) =='
SELECT u.nombre        AS lector,
       u.correo,
       u.telefono,
       l.titulo,
       vp.num_ejemplar,
       vp.fecha_pactada,
       vp.dias_mora,
       vp.estado_mora
FROM   biblioteca.vista_prestamo vp
JOIN   biblioteca.usuario u
       ON u.id_usuario = vp.id_usuario
JOIN   biblioteca.libro l
       ON l."ISBN" = vp."ISBN"
WHERE  vp.fecha_real IS NULL
  AND  vp.estado_mora = 'Con mora'
ORDER BY vp.fecha_pactada;