-- =====================================================================
-- parte-a.sql · S16 · Parte A: ejercicios sobre el esquema "tienda"
--
-- Se excluyen los pedidos con estado = 'cancelado'.
-- El valor de una línea es cantidad * precio_unitario.
-- =====================================================================

SET search_path TO tienda;

-- ---------------------------------------------------------------------
-- Ejercicio 1. Pedido 1003: cliente, producto, cantidad y subtotal.
-- Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT c.nombre                       AS cliente,
       pr.nombre                      AS producto,
       d.cantidad,
       d.cantidad * d.precio_unitario AS subtotal
FROM   pedido p
JOIN   cliente  c  ON c.id_cliente  = p.id_cliente
JOIN   detalle  d  ON d.id_pedido   = p.id_pedido
JOIN   producto pr ON pr.id_producto = d.id_producto
WHERE  p.id_pedido = 1003;

-- ---------------------------------------------------------------------
-- Ejercicio 2. Cada cliente con el nombre de quien lo refirió los que
-- llegaron solos también aparecen (self-join externo).
-- Filas esperadas: 8
-- ---------------------------------------------------------------------
SELECT c.id_cliente,
       c.nombre,
       r.nombre AS referido_por
FROM   cliente c
LEFT JOIN cliente r ON r.id_cliente = c.referido_por
ORDER BY c.id_cliente;

-- ---------------------------------------------------------------------
-- Ejercicio 3. Productos que nunca se han vendido (en ningún pedido,
-- ni siquiera cancelado): anti-join.
-- Filas esperadas: 1
-- ---------------------------------------------------------------------
SELECT pr.id_producto,
       pr.nombre
FROM   producto pr
LEFT JOIN detalle d ON d.id_producto = pr.id_producto
WHERE  d.id_producto IS NULL;

-- ---------------------------------------------------------------------
-- Ejercicio 4. Cada cliente con su número de pedidos (todos, incluidos
-- los cancelados), con 0 para quien no tiene, De más a menos pedidos.
-- count(p.id_pedido) y no count(*): count(*) contaría 1 para quien no
-- tiene pedidos, porque el LEFT JOIN deja una fila con NULL.
-- Filas esperadas: 8
-- ---------------------------------------------------------------------
SELECT c.nombre,
       count(p.id_pedido) AS pedidos
FROM   cliente c
LEFT JOIN pedido p ON p.id_cliente = c.id_cliente
GROUP BY c.id_cliente, c.nombre
ORDER BY pedidos DESC, c.nombre;

-- ---------------------------------------------------------------------
-- Ejercicio 5. Total vendido por categoría, sin cancelados, de mayor a
-- menor.
-- Filas esperadas: 3
-- ---------------------------------------------------------------------
SELECT pr.categoria,
       sum(d.cantidad * d.precio_unitario) AS total_vendido
FROM   pedido p
JOIN   detalle  d  ON d.id_pedido    = p.id_pedido
JOIN   producto pr ON pr.id_producto = d.id_producto
WHERE  p.estado <> 'cancelado'
GROUP BY pr.categoria
ORDER BY total_vendido DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 6. Meses de 2026 en que las ventas (sin cancelados) pasaron
-- de 200.000, con su total. El filtro por el total va en HAVING porque
-- depende del agregado.
-- Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT extract(month FROM p.fecha)::integer AS mes,
       sum(d.cantidad * d.precio_unitario)  AS total_mes
FROM   pedido p
JOIN   detalle d ON d.id_pedido = p.id_pedido
WHERE  p.estado <> 'cancelado'
  AND  extract(year FROM p.fecha) = 2026
GROUP BY extract(month FROM p.fecha)
HAVING sum(d.cantidad * d.precio_unitario) > 200000
ORDER BY mes;

-- ---------------------------------------------------------------------
-- Ejercicio 7. Productos cuyo precio es mayor que el precio promedio de
-- su categoría (subconsulta correlacionada).
-- Filas esperadas: 4
-- ---------------------------------------------------------------------
SELECT p.id_producto,
       p.nombre,
       p.categoria,
       p.precio
FROM   producto p
WHERE  p.precio > (SELECT avg(p2.precio)
                   FROM   producto p2
                   WHERE  p2.categoria = p.categoria)
ORDER BY p.categoria, p.precio DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 8. Clientes de Cali que han comprado al menos un accesorio,
-- sin cancelados. EXISTS evita repetir al cliente que compró varios.
-- Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT c.id_cliente,
       c.nombre
FROM   cliente c
WHERE  c.ciudad = 'Cali'
  AND  EXISTS (SELECT 1
               FROM   pedido p
               JOIN   detalle  d  ON d.id_pedido    = p.id_pedido
               JOIN   producto pr ON pr.id_producto = d.id_producto
               WHERE  p.id_cliente = c.id_cliente
                 AND  p.estado <> 'cancelado'
                 AND  pr.categoria = 'Accesorio')
ORDER BY c.nombre;

-- ---------------------------------------------------------------------
-- Ejercicio 9. Clientes que no han referido a nadie.
--
-- La consulta del compañero devuelve 0 filas:
--   SELECT nombre FROM cliente
--   WHERE id_cliente NOT IN (SELECT referido_por FROM cliente);
--
-- Por qué: referido_por es NULL para los clientes que llegaron solos
-- (hay 4). La subconsulta devuelve una lista con NULL, y "x NOT IN
-- (..., NULL)" equivale a "x <> ... AND x <> NULL". Comparar con NULL da
-- UNKNOWN, así que la condición nunca se cumple para
-- ningún cliente y el resultado queda vacío.
--
-- Versión correcta con NOT EXISTS, que no se confunde con los NULL:
-- Filas esperadas: 5
-- ---------------------------------------------------------------------
SELECT c.id_cliente,
       c.nombre
FROM   cliente c
WHERE  NOT EXISTS (SELECT 1
                   FROM   cliente r
                   WHERE  r.referido_por = c.id_cliente)
ORDER BY c.id_cliente;

-- ---------------------------------------------------------------------
-- Ejercicio 10. El o los clientes que más han gastado (sin cancelados),
-- con su total. Se compara contra el máximo, no se usa LIMIT 1, para
-- que los empates salgan todos.
-- Filas esperadas: 2
-- ---------------------------------------------------------------------
WITH gasto AS (
    SELECT c.id_cliente,
           c.nombre,
           sum(d.cantidad * d.precio_unitario) AS total_gastado
    FROM   cliente c
    JOIN   pedido  p ON p.id_cliente = c.id_cliente
    JOIN   detalle d ON d.id_pedido  = p.id_pedido
    WHERE  p.estado <> 'cancelado'
    GROUP BY c.id_cliente, c.nombre
)
SELECT nombre,
       total_gastado
FROM   gasto
WHERE  total_gastado = (SELECT max(total_gastado) FROM gasto)
ORDER BY nombre;

-- ---------------------------------------------------------------------
-- Ejercicio 11. Clientes que han comprado TODOS los productos de la
-- categoría Grano, sin cancelados (división con NOT EXISTS doble):
-- clientes para los que NO existe un producto de Grano que NO hayan
-- comprado.
-- Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT c.id_cliente,
       c.nombre
FROM   cliente c
WHERE  NOT EXISTS (
           SELECT 1
           FROM   producto pr
           WHERE  pr.categoria = 'Grano'
             AND  NOT EXISTS (
                      SELECT 1
                      FROM   pedido  p
                      JOIN   detalle d ON d.id_pedido = p.id_pedido
                      WHERE  p.id_cliente  = c.id_cliente
                        AND  p.estado     <> 'cancelado'
                        AND  d.id_producto = pr.id_producto))
ORDER BY c.nombre;