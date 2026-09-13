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

La URL y la clave anon van fijas en `index.html`, en las constantes `SUPABASE_URL` y `SUPABASE_KEY` al principio del script. Con eso todos los dispositivos se conectan solos. (Si están vacías, la página muestra en Ajustes un panel para pegarlas a mano en cada dispositivo.)

## Cómo se usa

- **La página siempre arranca en modo fichaje.** Muestra el reloj, el turno y una tarjeta por empleado. Nada más.
- **Autorizar un dispositivo.** La primera vez que se abre en un dispositivo nuevo (el iPad, tu celular) pide un nombre y el **PIN del dueño**. Sin eso no muestra nada. Al principio el PIN es `1234`: cambialo enseguida.
- **Entrar a la administración.** En modo fichaje, tocá "Administración" arriba a la derecha y poné el PIN del dueño. Ahí están Semana, Planificar, Mes, Sueldos y Ajustes. El PIN se pide cada vez que se entra: no queda guardado.
- **Volver al fichaje.** Botón "Modo fichaje" arriba a la derecha. Al recargar la página también vuelve sola al fichaje.
- **Dar de baja un dispositivo.** Ajustes → Dispositivos autorizados → ✕. Deja de poder abrir la página al instante.
- **Alarmas de fichaje.** Ajustes → Alarmas de fichaje: hora de aviso de entrada y de salida por turno, y margen en minutos. En modo fichaje suena la alarma y aparece un cartel con quiénes faltan; pasado el margen, a quien siga "dentro" se le ficha la salida sola (queda marcada como automática). El sonido necesita que alguien haya tocado la pantalla del iPad alguna vez desde que se abrió la página.

## Uso en el iPad / tablet del local

1. Abrí la página en Safari, autorizá el dispositivo con el PIN del dueño.
2. Aceptá el permiso de cámara la primera vez que alguien fiche.
3. Safari → botón compartir → **Añadir a pantalla de inicio**, así abre a pantalla completa.
4. Ajustes del iPad → Pantalla y brillo → Bloqueo automático → **Nunca**, y dejalo enchufado.
5. Recomendado: activar **Acceso Guiado** (Ajustes → Accesibilidad) para que el iPad quede fijo en la página.

## Cómo está protegido

- El archivo de la página es público (está en GitHub Pages), pero no sirve de nada sin autorización: cada llamada a Supabase pasa por una función que exige un dispositivo autorizado (para fichar), el PIN del empleado (para fichar en su nombre) o el PIN del dueño (para ver o editar cualquier cosa).
- Las fotos se guardan en la base de datos y solo se pueden ver con el PIN del dueño.
- La clave `anon` de Supabase es pública por diseño; por sí sola no da acceso a nada porque las tablas tienen acceso denegado y solo las funciones pueden tocarlas.
- Cambiá el PIN del dueño (`1234`) apenas conectes.

## Archivos

- `index.html` — toda la aplicación.
- `schema.sql` — tablas y funciones para Supabase.
- `migrar.py` — importa a Supabase los datos exportados de la versión anterior (carpeta `migracion/`, que no se sube al repositorio).

## Cambiar algo

Editá `index.html` y hacé commit en la rama `main`. GitHub Pages publica el cambio en uno o dos minutos.

Si cambia `schema.sql`, hay que volver a pegarlo entero en el SQL Editor de Supabase y ejecutarlo. Se puede correr las veces que haga falta: no borra datos.
