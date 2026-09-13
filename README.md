# Terry's Horarios

Control de días, horarios, horas trabajadas, sueldos y fichaje del personal de Terry's Burgers. Es una sola página (`index.html`) que se publica en GitHub Pages y guarda todo en un proyecto de Supabase.

- **Página:** https://jetraverso.github.io/terrys-horarios/
- **Base de datos:** Supabase (gratis). Guarda la configuración, los turnos, los ajustes de sueldo y las fotos del fichaje.

## Puesta en marcha (una sola vez, 10 minutos)

### 1. Crear el proyecto en Supabase

1. Entrá a https://supabase.com y creá una cuenta (o iniciá sesión).
2. **New project**. Poné un nombre (por ejemplo `terrys-horarios`), una contraseña de base de datos (guardala, aunque la página no la usa) y elegí la región **West EU (Ireland)** o la más cercana.
3. Esperá un minuto a que el proyecto termine de crearse.

### 2. Crear las tablas y funciones

1. En el menú de la izquierda, abrí **SQL Editor**.
2. Abrí el archivo [`schema.sql`](schema.sql) de este repositorio, copiá **todo** su contenido y pegalo en el editor.
3. Tocá **Run**. Tiene que decir "Success. No rows returned".

Eso crea las tablas y las funciones que verifican los PIN. Nadie puede leer ni escribir las tablas directamente: todo pasa por esas funciones.

### 3. Copiar los datos de conexión

1. En el menú de la izquierda, **Project Settings** (el engranaje) → **API**.
2. Copiá la **Project URL** (algo como `https://abcdefgh.supabase.co`).
3. Copiá la clave **anon / public** (una clave larga). Es la clave pública: está pensada para ir en páginas web. La que **nunca** hay que pegar en la página es la `service_role`.

### 4. Conectar la página

1. Abrí https://jetraverso.github.io/terrys-horarios/
2. Pestaña **Ajustes** → panel **Conexión con Supabase**. Pegá la URL y la clave anon y tocá **Conectar**.
3. La página se recarga y pide el **PIN del dueño**. Al principio es `1234`. Cambialo enseguida en Ajustes → Modo fichaje.
4. Cargá los empleados, sus PIN y los horarios.

Hay que hacer el paso 4 en cada dispositivo que use la página (tu celular, la tablet del local). Si preferís no pegar los datos en cada uno, se pueden dejar fijos en `index.html` en las constantes `SUPABASE_URL` y `SUPABASE_KEY` del principio del script.

## Uso en el iPad / tablet del local

1. Abrí la página en Safari, conectala (paso 4) y tocá **Modo fichaje**.
2. Aceptá el permiso de cámara la primera vez.
3. Safari → botón compartir → **Añadir a pantalla de inicio**, así abre a pantalla completa.
4. Ajustes del iPad → Pantalla y brillo → Bloqueo automático → **Nunca**, y dejalo enchufado.
5. Recomendado: activar **Acceso Guiado** (Ajustes → Accesibilidad) para que el iPad quede fijo en la página.

En modo fichaje la página no muestra sueldos ni horarios: solo los nombres y los fichajes del día. Para salir hace falta el PIN del dueño.

## Cómo está protegido

- La página es pública, pero los datos no: cada llamada a Supabase pasa por una función que exige el PIN del dueño (para ver o editar) o el PIN del empleado (para fichar).
- Las fotos se guardan en la base de datos y solo se pueden ver con el PIN del dueño.
- La clave `anon` de Supabase es pública por diseño; por sí sola no da acceso a nada porque las tablas tienen acceso denegado sin funciones.
- Cambiá el PIN del dueño (`1234`) apenas conectes.

## Archivos

- `index.html` — toda la aplicación (funciona también como artifact de claude.ai y como archivo local sin conexión).
- `schema.sql` — tablas y funciones para Supabase.

## Cambiar algo

Editá `index.html` y hacé commit en la rama `main`. GitHub Pages publica el cambio en uno o dos minutos.
