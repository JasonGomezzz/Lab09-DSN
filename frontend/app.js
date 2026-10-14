const API = '';

const TIPOS_PERMITIDOS = ['image/jpeg', 'image/png', 'image/webp'];
// El backend vuelve a validar; esta comprobación solo evita viajes inútiles.
const TAMANO_MAXIMO = 5 * 1024 * 1024;
const MSG_RED = 'No se pudo conectar con el servidor. Revisa tu conexión e inténtalo de nuevo.';
const MSG_FORMATO = 'La respuesta del servidor no tiene el formato esperado.';

const $ = (id) => document.getElementById(id);

const ui = {
  form: $('upload-form'),
  input: $('file-input'),
  dropzone: $('dropzone'),
  selected: $('selected-file'),
  submit: $('submit-btn'),
  progressRow: $('progress-row'),
  progress: $('progress'),
  progressText: $('progress-text'),
  status: $('status'),
  section: $('galeria'),
  heading: $('titulo-galeria'),
  gallery: $('gallery'),
  galleryState: $('gallery-state'),
  count: $('gallery-count'),
  tagProyecto: $('tag-proyecto'),
  tagCliente: $('tag-cliente'),
  filterForm: $('filter-form'),
  filterProyecto: $('filter-proyecto'),
  filterCliente: $('filter-cliente'),
  filterClear: $('filter-clear'),
};

let archivo = null;
let subiendo = false;
let cargaActual = 0;

const formatoNumero = new Intl.NumberFormat('es', { maximumFractionDigits: 1 });
const formatoFecha = new Intl.DateTimeFormat('es', { dateStyle: 'medium', timeStyle: 'short' });

/* ---------- utilidades ---------- */

function el(tag, { className, text, attrs, data } = {}) {
  const nodo = document.createElement(tag);
  if (className) nodo.className = className;
  if (text !== undefined) nodo.textContent = text;
  if (attrs) for (const [k, v] of Object.entries(attrs)) nodo.setAttribute(k, v);
  if (data) for (const [k, v] of Object.entries(data)) nodo.dataset[k] = v;
  return nodo;
}

function formatearTamano(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '-';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${formatoNumero.format(bytes / 1024)} KB`;
  return `${formatoNumero.format(bytes / (1024 * 1024))} MB`;
}

function formatearFecha(valor) {
  const fecha = new Date(valor);
  return Number.isNaN(fecha.getTime()) ? 'Fecha desconocida' : formatoFecha.format(fecha);
}

// La clave es "originales/<marca de tiempo>-<hex>-<nombre>.ext"; se muestra solo el nombre.
function nombreCorto(key) {
  const base = String(key).split('/').pop() || String(key);
  const sinPrefijo = base.replace(/^\d{10,}-[0-9a-f]{12}-/, '');
  return sinPrefijo || base;
}

function setStatus(texto, tipo = '') {
  ui.status.textContent = texto;
  if (tipo) ui.status.dataset.kind = tipo;
  else delete ui.status.dataset.kind;
}

function setError(error) {
  setStatus(`Error: ${error.message}`, 'error');
}

/* ---------- red ---------- */

// Devuelve el JSON de la respuesta o lanza Error con un mensaje apto para el usuario.
async function pedirJson(ruta, opciones) {
  let res;
  try {
    res = await fetch(API + ruta, opciones);
  } catch {
    throw new Error(MSG_RED);
  }

  let datos = null;
  try {
    datos = await res.json();
  } catch {
    // Cuerpo vacío o que no es JSON: se trata más abajo según el código HTTP.
  }

  if (!res.ok) {
    const mensaje = datos && typeof datos.error === 'string' && datos.error
      ? datos.error
      : `El servidor respondió con un error (HTTP ${res.status}).`;
    throw new Error(mensaje);
  }
  if (datos === null) throw new Error(MSG_FORMATO);
  return datos;
}

function enviarJson(ruta, metodo, cuerpo) {
  return pedirJson(ruta, {
    method: metodo,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(cuerpo),
  });
}

// PUT directo a S3 con exactamente los encabezados firmados; XHR para medir el progreso.
function subirAS3(firma, file, alProgresar) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', firma.uploadUrl);
    for (const [nombre, valor] of Object.entries(firma.headers)) {
      xhr.setRequestHeader(nombre, valor);
    }
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) alProgresar(Math.round((e.loaded / e.total) * 100));
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else reject(new Error(`La subida falló (HTTP ${xhr.status}).`));
    };
    xhr.onerror = () => reject(new Error('La subida falló: no se pudo conectar con S3.'));
    xhr.onabort = () => reject(new Error('La subida fue cancelada.'));
    xhr.send(file);
  });
}

/* ---------- selección y validación ---------- */

function validarArchivo(file) {
  if (!file) return 'Selecciona una imagen antes de subir.';
  if (!TIPOS_PERMITIDOS.includes(file.type)) {
    return `Tipo de archivo no permitido (${file.name}). Solo se aceptan imágenes JPG, PNG o WebP.`;
  }
  if (file.size === 0) return 'El archivo está vacío.';
  if (file.size >= TAMANO_MAXIMO) {
    return `La imagen es demasiado grande (${formatearTamano(file.size)}). Debe pesar menos de 5 MB.`;
  }
  return null;
}

function mostrarSeleccion() {
  ui.selected.textContent = archivo
    ? `Archivo seleccionado: ${archivo.name} (${formatearTamano(archivo.size)})`
    : 'Ningún archivo seleccionado.';
}

function seleccionarArchivo(file) {
  const problema = file ? validarArchivo(file) : null;
  if (problema) {
    archivo = null;
    ui.input.value = '';
    mostrarSeleccion();
    setStatus(`Error: ${problema}`, 'error');
    return false;
  }
  archivo = file || null;
  mostrarSeleccion();
  setStatus('');
  return true;
}

function setOcupado(ocupado) {
  subiendo = ocupado;
  ui.submit.disabled = ocupado;
  ui.input.disabled = ocupado;
  ui.dropzone.classList.toggle('is-disabled', ocupado);
  ui.form.setAttribute('aria-busy', String(ocupado));
}

function setProgreso(porcentaje) {
  ui.progress.value = porcentaje;
  ui.progressText.textContent = `${porcentaje} %`;
}

/* ---------- flujo de subida ---------- */

async function subirImagen() {
  if (subiendo) return;
  setOcupado(true);
  try {
    setStatus('Validando archivo…', 'info');
    // Cede un turno al navegador para que el estado alcance a mostrarse.
    await new Promise((resolve) => setTimeout(resolve, 0));
    const problema = validarArchivo(archivo);
    if (problema) throw new Error(problema);

    setStatus('Solicitando URL de subida…', 'info');
    const firma = await enviarJson('/api/upload-url', 'POST', {
      filename: archivo.name,
      contentType: archivo.type,
      sizeBytes: archivo.size,
      tags: {
        proyecto: ui.tagProyecto.value.trim(),
        cliente: ui.tagCliente.value.trim(),
      },
    });
    const firmaValida = typeof firma.uploadUrl === 'string'
      && typeof firma.key === 'string'
      && firma.headers && typeof firma.headers === 'object';
    if (!firmaValida) throw new Error(MSG_FORMATO);

    setStatus('Subiendo imagen a S3…', 'info');
    setProgreso(0);
    ui.progressRow.hidden = false;
    await subirAS3(firma, archivo, setProgreso);
    ui.progressRow.hidden = true;

    setStatus('Verificando imagen…', 'info');
    await enviarJson('/api/verify', 'POST', { key: firma.key });

    archivo = null;
    ui.input.value = '';
    mostrarSeleccion();
    setStatus('Imagen subida y verificada correctamente.', 'ok');
    await cargarGaleria();
  } catch (error) {
    setError(error);
  } finally {
    ui.progressRow.hidden = true;
    setOcupado(false);
  }
}

/* ---------- galería ---------- */

function mostrarEstado(tipo, detalle = '') {
  ui.galleryState.replaceChildren();
  if (tipo === 'cargando') {
    ui.galleryState.append(el('p', { text: 'Cargando imágenes…' }));
  } else if (tipo === 'vacio') {
    ui.galleryState.append(
      el('p', { className: 'state-title', text: 'Aún no hay imágenes' }),
      el('p', { text: 'Sube la primera con el formulario de arriba.' }),
    );
  } else if (tipo === 'error') {
    ui.galleryState.append(
      el('p', { className: 'state-error', text: `No se pudo cargar la galería. ${detalle}` }),
      el('button', {
        className: 'btn',
        text: 'Reintentar',
        attrs: { type: 'button' },
        data: { action: 'reload' },
      }),
    );
  }
}

function actualizarConteo() {
  const total = ui.gallery.children.length;
  ui.count.textContent = total === 0 ? '' : `${total} ${total === 1 ? 'imagen' : 'imágenes'}`;
}

function crearInsignias(tags) {
  const lista = el('ul', { className: 'badges', attrs: { 'aria-label': 'Etiquetas' } });
  for (const [nombre, valor] of Object.entries(tags || {})) {
    if (typeof valor !== 'string') continue;
    lista.append(el('li', { className: 'badge', text: `${nombre}: ${valor}` }));
  }
  return lista;
}

function crearTarjeta(imagen) {
  const nombre = nombreCorto(imagen.key);

  const tarjeta = el('li', { className: 'card', data: { key: imagen.key } });
  const media = el('div', { className: 'card-media' });
  // La miniatura (generada por la función Lambda) pesa menos; si aún no existe
  // se muestra el original.
  const origen = typeof imagen.thumbUrl === 'string' ? imagen.thumbUrl : imagen.url;
  media.append(el('img', {
    attrs: { loading: 'lazy', decoding: 'async', alt: nombre, src: origen },
  }));

  const cuerpo = el('div', { className: 'card-body' });
  cuerpo.append(
    el('p', { className: 'card-name', text: nombre, attrs: { title: nombre } }),
    el('p', {
      className: 'card-meta',
      text: `${formatearTamano(imagen.size)} · ${formatearFecha(imagen.lastModified)}`,
    }),
    crearInsignias(imagen.tags),
    el('a', {
      className: 'card-link',
      text: 'Ver original',
      attrs: { href: imagen.url, target: '_blank', rel: 'noopener noreferrer' },
    }),
    el('button', {
      className: 'btn btn-danger',
      text: 'Eliminar',
      attrs: { type: 'button', 'aria-label': `Eliminar ${nombre}` },
      data: { action: 'delete', key: imagen.key },
    }),
  );

  tarjeta.append(media, cuerpo);
  return tarjeta;
}

function renderizarGaleria(imagenes) {
  const validas = imagenes.filter(
    (i) => i && typeof i.key === 'string' && typeof i.url === 'string',
  );
  ui.gallery.replaceChildren(...validas.map(crearTarjeta));
  actualizarConteo();
  if (validas.length === 0) mostrarEstado('vacio');
  else ui.galleryState.replaceChildren();
}

async function cargarGaleria() {
  const id = ++cargaActual;
  if (ui.gallery.children.length === 0) mostrarEstado('cargando');

  try {
    const filtro = new URLSearchParams();
    if (ui.filterProyecto.value.trim()) filtro.set('proyecto', ui.filterProyecto.value.trim());
    if (ui.filterCliente.value.trim()) filtro.set('cliente', ui.filterCliente.value.trim());
    const consulta = filtro.toString();
    const datos = await pedirJson(`/api/images${consulta ? `?${consulta}` : ''}`);
    if (id !== cargaActual) return;
    if (!Array.isArray(datos)) throw new Error(MSG_FORMATO);
    renderizarGaleria(datos);
  } catch (error) {
    if (id !== cargaActual) return;
    mostrarEstado('error', error.message);
  }
}

async function eliminarImagen(key, boton) {
  const nombre = nombreCorto(key);
  if (!window.confirm(`¿Eliminar "${nombre}"? Esta acción no se puede deshacer.`)) return;

  boton.disabled = true;
  setStatus(`Eliminando ${nombre}…`, 'info');
  try {
    await pedirJson(`/api/images/${encodeURIComponent(key)}`, { method: 'DELETE' });
    const tarjeta = boton.closest('.card');
    if (tarjeta) tarjeta.remove();
    actualizarConteo();
    if (ui.gallery.children.length === 0) mostrarEstado('vacio');
    setStatus('Imagen eliminada.', 'ok');
    // El botón pulsado ya no existe: se devuelve el foco a un punto estable.
    ui.heading.focus();
  } catch (error) {
    boton.disabled = false;
    setError(error);
  }
}

/* ---------- eventos ---------- */

ui.form.addEventListener('submit', (e) => {
  e.preventDefault();
  if (!archivo) {
    setStatus('Error: Selecciona una imagen antes de subir.', 'error');
    return;
  }
  subirImagen();
});

ui.input.addEventListener('change', () => {
  if (subiendo) return;
  seleccionarArchivo(ui.input.files[0] || null);
});

ui.dropzone.addEventListener('dragover', (e) => {
  e.preventDefault();
  if (e.dataTransfer) e.dataTransfer.dropEffect = subiendo ? 'none' : 'copy';
  if (!subiendo) ui.dropzone.classList.add('is-dragover');
});

ui.dropzone.addEventListener('dragleave', (e) => {
  if (!ui.dropzone.contains(e.relatedTarget)) ui.dropzone.classList.remove('is-dragover');
});

ui.dropzone.addEventListener('drop', (e) => {
  e.preventDefault();
  ui.dropzone.classList.remove('is-dragover');
  if (subiendo) return;
  const archivos = e.dataTransfer ? e.dataTransfer.files : null;
  if (!archivos || archivos.length === 0) return;
  const valido = seleccionarArchivo(archivos[0]);
  if (valido && archivos.length > 1) {
    setStatus('Solo se sube una imagen a la vez; se tomó la primera.', 'info');
  }
});

ui.filterForm.addEventListener('submit', (e) => {
  e.preventDefault();
  cargarGaleria();
});

ui.filterClear.addEventListener('click', () => {
  ui.filterProyecto.value = '';
  ui.filterCliente.value = '';
  cargarGaleria();
});

// Soltar un archivo fuera de la zona no debe hacer que el navegador abra la imagen.
for (const tipo of ['dragover', 'drop']) {
  window.addEventListener(tipo, (e) => {
    if (!ui.dropzone.contains(e.target)) e.preventDefault();
  });
}

// Delegación: un solo manejador para eliminar y recargar, sin manejadores en línea.
ui.section.addEventListener('click', (e) => {
  const boton = e.target.closest('button[data-action]');
  if (!boton || boton.disabled) return;
  if (boton.dataset.action === 'reload') cargarGaleria();
  else if (boton.dataset.action === 'delete') eliminarImagen(boton.dataset.key, boton);
});

// El evento error de <img> no burbujea; se captura en el contenedor.
ui.gallery.addEventListener('error', (e) => {
  if (!(e.target instanceof HTMLImageElement)) return;
  const media = e.target.closest('.card-media');
  if (!media) return;
  media.classList.add('is-expired');
  media.replaceChildren(
    el('p', { className: 'expired-text', text: 'El enlace expiró, recarga la galería.' }),
    el('button', {
      className: 'btn',
      text: 'Recargar',
      attrs: { type: 'button' },
      data: { action: 'reload' },
    }),
  );
}, true);

mostrarSeleccion();
cargarGaleria();
