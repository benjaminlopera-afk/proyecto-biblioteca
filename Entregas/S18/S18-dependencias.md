# S18 · Dependencias Funcionales y Claves Candidatas del Esquema `biblioteca`

**Curso:** 750006C Bases de Datos · Grupo 80  
**Grupo de proyecto:** 05  
**Integrantes:**
- Benjamin Lopera (`2515144`)
- Sebastian Martinez (`2519817`)
- Jhonny Moreno (`2522112`)
- Juan Pablo Lozano Restrepo (`2521505`)

**Objetivo (S18):** Identificar las claves candidatas y escribir todas las dependencias funcionales no triviales del esquema del proyecto (`postgres/init/01_esquema.sql`), tabla por tabla, junto con la regla del negocio que justifica cada una, detectando determinantes que no sean superclaves.

---

## 1. Decisiones de modelado sobre las reglas del negocio

Antes de formalizar las dependencias funcionales del esquema `biblioteca`, el equipo estableció cinco criterios de diseño alineados con las reglas de normalización vistas en S17 y S18:

1. **Detección de dato derivado en `prestamo.estado_mora`:**  
   En `01_esquema.sql`, la tabla `prestamo` almacena la columna `estado_mora`. Sin embargo, según las reglas del negocio, el estado de mora se determina a partir de `fecha_pactada` y `fecha_real` (`fecha_pactada, fecha_real → estado_mora`), y para préstamos abiertos depende además de la fecha actual (`CURRENT_DATE`). Como `{fecha_pactada, fecha_real}` no es superclave de `prestamo`, constituye una señal de mal diseño (redundancia de dato calculable) que se corregirá en la siguiente fase.
2. **Identificación de la clave natural en `prestamo`:**  
   Aunque `id_prestamo` es la clave primaria sustituta, una misma copia física de un libro (`"ISBN", "num_ejemplar"`) no puede prestarse dos veces en la misma fecha (`"fecha_prestamo"`). Por lo tanto, `{"ISBN", "num_ejemplar", "fecha_prestamo"}` es una segunda clave candidata que determina a todos los demás atributos de la tabla y debe protegerse con restricción `UNIQUE`.
3. **Alcance de `ejemplar.estado` (condición física vs. disponibilidad):**  
   La disponibilidad de préstamo de una copia física se deduce de la tabla `prestamo` (verificando si existe un registro abierto con `fecha_real IS NULL`). Para no duplicar información derivada, `ejemplar.estado` representa únicamente la **condición física** del ejemplar (`bueno`, `regular`, `dañado`, `en reparación`), la cual depende exclusivamente de `("ISBN", "num_ejemplar")`.
4. **Carácter histórico de `prestamo.fecha_pactada`:**  
   Aunque el plazo estándar de préstamo sea de 14 días, `fecha_pactada` registra la fecha límite acordada al momento de realizar el préstamo (la cual puede variar por tipo de usuario, políticas vigentes o renovaciones). En consecuencia, es un hecho histórico que depende de `id_prestamo` y no un dato redundante calculado desde `fecha_prestamo`.
5. **Atomicidad de `libro.editorial`:**  
   El atributo `editorial` es un valor atómico que depende directamente de `ISBN`. Dado que el esquema no almacena atributos propios de la editorial (como ciudad o teléfono de la editorial), no se generan dependencias transitivas dentro de `libro`.

---

## 2. Análisis de claves candidatas y dependencias funcionales por tabla

### 2.1 `categoria ("id_categoria", "nombre")`
- **Claves candidatas:** `{"id_categoria"}` (PK), `{"nombre"}` (clave alterna `UNIQUE`).
- **Dependencias funcionales:**
  - `"id_categoria" → "nombre"`: Cada identificador de categoría corresponde a una única categoría temática del catálogo.
  - `"nombre" → "id_categoria"`: No pueden existir dos categorías distintas con el mismo nombre en la biblioteca.
- **Diagnóstico de determinantes:** Todo determinante es superclave.

### 2.2 `autor ("id_autor", "nombre", "nacionalidad")`
- **Claves candidatas:** `{"id_autor"}` (PK), `{"nombre"}` (clave alterna `UNIQUE`).
- **Dependencias funcionales:**
  - `"id_autor" → "nombre", "nacionalidad"`: Cada código de autor identifica a una única persona registrada, con un nombre y una nacionalidad asociados.
  - `"nombre" → "id_autor", "nacionalidad"`: Cada autor se registra bajo un nombre único dentro del catálogo.
- **Diagnóstico de determinantes:** Todo determinante es superclave.

### 2.3 `libro ("ISBN", "id_categoria", "titulo", "editorial", "ano_publicacion")`
- **Claves candidatas:** `{"ISBN"}` (PK). *(Nota: `"titulo"` no es clave porque distintas ediciones u obras pueden compartir título).*
- **Dependencias funcionales:**
  - `"ISBN" → "id_categoria", "titulo", "editorial", "ano_publicacion"`: Un ISBN identifica de manera única una edición bibliográfica específica, la cual pertenece a una sola categoría y posee un único título, editorial y año de publicación.
- **Diagnóstico de determinantes:** Todo determinante es superclave.

### 2.4 `libro_autor ("ISBN", "id_autor")`
- **Claves candidatas:** `{"ISBN", "id_autor"}` (PK compuesta).
- **Dependencias funcionales:**
  - Solo dependencias triviales (`"ISBN", "id_autor" → "ISBN", "id_autor"`): Un libro puede tener varios autores y un autor puede escribir varios libros (relación muchos a muchos); la tabla solo registra la asociación de autoría sin atributos adicionales, evitando listas multivaluadas en `libro`.
- **Diagnóstico de determinantes:** No existen dependencias no triviales; cumple con valores atómicos.

### 2.5 `ejemplar ("ISBN", "num_ejemplar", "estado", "ubicacion")`
- **Claves candidatas:** `{"ISBN", "num_ejemplar"}` (PK compuesta).
- **Dependencias funcionales:**
  - `"ISBN", "num_ejemplar" → "estado", "ubicacion"`: El número de ejemplar se asigna secuencialmente dentro de cada ISBN; la combinación identifica una copia física individual en el inventario, con una condición física (`estado`) y una ubicación en estantería (`ubicacion`) propias.
- **Diagnóstico de determinantes:** Todo determinante es superclave (bajo la regla de que `estado` representa condición física y no disponibilidad de préstamo).

### 2.6 `rol ("id_rol", "nombre_rol")`
- **Claves candidatas:** `{"id_rol"}` (PK), `{"nombre_rol"}` (clave alterna `UNIQUE`).
- **Dependencias funcionales:**
  - `"id_rol" → "nombre_rol"`: Cada código de rol (`ADMIN`, `BIBLIO`, `LECTOR`, `AUDITOR`) define un único perfil de permisos en el sistema.
  - `"nombre_rol" → "id_rol"`: Cada nombre de rol es único y corresponde a un solo identificador de rol.
- **Diagnóstico de determinantes:** Todo determinante es superclave.

### 2.7 `usuario ("id_usuario", "id_rol", "nombre", "correo", "telefono", "contrasena")`
- **Claves candidatas:** `{"id_usuario"}` (PK), `{"correo"}` (clave alterna `UNIQUE`).
- **Dependencias funcionales:**
  - `"id_usuario" → "id_rol", "nombre", "correo", "telefono", "contrasena"`: Cada documento de identidad (`id_usuario`) identifica a una única persona registrada en la biblioteca, con un rol, nombre, correo, teléfono y contraseña asignados.
  - `"correo" → "id_usuario", "id_rol", "nombre", "telefono", "contrasena"`: El correo electrónico es único por cuenta y no puede compartirse entre dos usuarios distintos.
- **Diagnóstico de determinantes:** Todo determinante es superclave.

### 2.8 `prestamo ("id_prestamo", "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario", "fecha_prestamo", "fecha_pactada", "fecha_real", "estado_mora")`
- **Claves candidatas:** `{"id_prestamo"}` (PK sustituta) y `{"ISBN", "num_ejemplar", "fecha_prestamo"}` (clave natural alterna, pendiente de restricción `UNIQUE`).
- **Dependencias funcionales:**
  - `"id_prestamo" → "ISBN", "num_ejemplar", "id_usuario", "id_bibliotecario", "fecha_prestamo", "fecha_pactada", "fecha_real", "estado_mora"`: Cada comprobante de préstamo identifica una transacción única realizada sobre un ejemplar específico, solicitada por un lector, autorizada por un bibliotecario, en una fecha de inicio, con una fecha límite pactada y una fecha real de devolución.
  - `"ISBN", "num_ejemplar", "fecha_prestamo" → "id_prestamo", "id_usuario", "id_bibliotecario", "fecha_pactada", "fecha_real", "estado_mora"`: Una misma copia física de un libro no puede prestarse más de una vez en el mismo día, por lo que la combinación identifica unívocamente el préstamo.
  - `"fecha_pactada", "fecha_real" → "estado_mora"` *(dependencia problemática)*: El estado de mora se deriva de comparar la fecha de entrega (real o actual) contra la fecha pactada.
- **Diagnóstico de determinantes:** Presenta dos hallazgos para corregir en la etapa de normalización:
  1. El determinante `{"fecha_pactada", "fecha_real"}` **no es superclave**, lo que introduce redundancia de dato derivado (`estado_mora`).
  2. La clave candidata natural `{"ISBN", "num_ejemplar", "fecha_prestamo"}` no cuenta aún con restricción `UNIQUE` en `01_esquema.sql`.
  3. fecha_prestamo no determina a fecha_pactada (fecha_prestamo ↛ fecha_pactada), ya que el plazo pactado puede variar por tipo de usuario o renovaciones y refleja el acuerdo histórico de cada préstamo.