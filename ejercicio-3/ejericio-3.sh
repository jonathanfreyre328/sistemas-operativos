#!/usr/bin/env bash

set -o pipefail

declare -r DIRECTORIO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r ARCHIVO_BD="$DIRECTORIO_SCRIPT/data.sq3"
declare -r ARCHIVO_LOG="$DIRECTORIO_SCRIPT/system.log"
declare -r ARCHIVO_LOG_ERRORES="$DIRECTORIO_SCRIPT/error.log"
declare -r ARCHIVO_REPORTE="$DIRECTORIO_SCRIPT/productos.html"

declare USUARIO_ID=""
declare USUARIO_ACTUAL=""

registrar_error() {
    local mensaje="$1"
    printf "%s\t%s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$ARCHIVO_LOG_ERRORES"
}

registrar_accion() {
    local accion="$1"
    printf "%s\t%s\t%s\t%s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${USUARIO_ID:--}" \
        "${USUARIO_ACTUAL:--}" \
        "$accion" >> "$ARCHIVO_LOG"
}

sql_escape() {
    local valor="$1"
    valor=${valor//\'/\'\'}
    printf "%s" "$valor"
}

ejecutar_sql() {
    local consulta="$1"
    local resultado

    resultado=$(sqlite3 -batch "$ARCHIVO_BD" "$consulta" 2>&1)
    local estado=$?
    if (( estado != 0 )); then
        registrar_error "Error SQLite: $resultado"
        return "$estado"
    fi
    printf "%s" "$resultado"
}

inicializar_base_datos() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        registrar_error "SQLite3 no esta instalado."
        printf "Error: SQLite3 no esta instalado.\n" >&2
        return 1
    fi

    if [[ ! -f "$ARCHIVO_BD" ]]; then
        if ! sqlite3 "$ARCHIVO_BD" <<'SQL'
CREATE TABLE usuarios (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL
);
CREATE TABLE productos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    nombre TEXT NOT NULL,
    precio REAL NOT NULL
);
SQL
        then
            registrar_error "No se pudo crear la base de datos."
            return 1
        fi
    fi

    touch "$ARCHIVO_LOG" 2>/dev/null || {
        registrar_error "No se pudo inicializar el archivo de log del sistema."
        return 1
    }
    touch "$ARCHIVO_LOG_ERRORES" 2>/dev/null || {
        printf "Error: no se pudo abrir el log de errores.\n" >&2
        return 1
    }
}

obtener_hash() {
    printf "%s" "$1" | sha256sum | cut -d' ' -f1
}

existe_usuario() {
    local usuario
    usuario=$(sql_escape "$1")
    [[ -n "$(ejecutar_sql "SELECT 1 FROM usuarios WHERE username = '$usuario' LIMIT 1;")" ]]
}

existe_producto() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$(ejecutar_sql "SELECT 1 FROM productos WHERE id = $1 LIMIT 1;")" ]]
}

registrar_usuario() {
    local user pass hash
    printf "\nREGISTRO DE USUARIO\n"
    read -rp "Ingrese nuevo nombre de usuario: " user

    if [[ -z "$user" ]]; then
        printf "El usuario no puede estar vacio.\n"
        registrar_error "El usuario no puede estar vacio."
        return
    fi

    if existe_usuario "$user"; then
        printf "Error: El usuario '%s' ya existe.\n" "$user"
        registrar_error "El usuario '$user' ya existe."
        return
    fi

    read -rsp "Ingrese contraseña: " pass
    printf "\n"

    if [[ -z "$pass" ]]; then
        printf "La contraseña no puede estar vacia.\n"
        registrar_error "La contraseña no puede estar vacia."
        return
    fi

    hash=$(obtener_hash "$pass")
    user=$(sql_escape "$user")
    if ejecutar_sql "INSERT INTO usuarios (username, password_hash) VALUES ('$user', '$hash');" >/dev/null; then
        printf "Usuario '%s' registrado exitosamente.\n" "${user//\'\'/\'}"
    else
        printf "Error: no se pudo registrar el usuario.\n"
    fi
}

iniciar_sesion() {
    local user pass hash datos
    local intentos=0
    printf "\nINICIO DE SESION\n"

    if [[ -z "$(ejecutar_sql "SELECT 1 FROM usuarios LIMIT 1;")" ]]; then
        printf "No hay usuarios registrados en el sistema. Registre uno primero.\n"
        registrar_error "No hay usuarios registrados en el sistema. Registre uno primero."
        return 1
    fi

    while (( intentos < 3 )); do
        read -rp "Usuario: " user
        read -rsp "Contraseña: " pass
        printf "\n"
        hash=$(obtener_hash "$pass")
        user=$(sql_escape "$user")
        datos=$(ejecutar_sql "SELECT id || char(9) || username FROM usuarios WHERE username = '$user' AND password_hash = '$hash' LIMIT 1;")

        if [[ -n "$datos" ]]; then
            IFS=$'\t' read -r USUARIO_ID USUARIO_ACTUAL <<< "$datos"
            printf "Acceso concedido. Bienvenido/a, %s.\n" "$USUARIO_ACTUAL"
            return 0
        fi

        intentos=$((intentos + 1))
        printf "Credenciales incorrectas (%d/3 intentos).\n" "$intentos"
    done

    registrar_error "Inicio de sesion fallido: se agotaron los intentos."
    return 1
}

alta_producto() {
    local nombre precio nombre_sql
    printf "\nALTA DE PRODUCTO\n"
    read -rp "Ingrese Nombre del producto: " nombre
    read -rp "Ingrese Precio del producto: " precio

    if [[ -z "$nombre" || -z "$precio" ]]; then
        printf "Error: El nombre y el precio son obligatorios.\n"
        registrar_error "El nombre y el precio son obligatorios."
        return
    fi
    if [[ ! "$precio" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf "Error: El precio debe ser numerico.\n"
        registrar_error "El precio '$precio' no es numerico."
        return
    fi

    nombre_sql=$(sql_escape "$nombre")
    local id
    id=$(ejecutar_sql "INSERT INTO productos (nombre, precio) VALUES ('$nombre_sql', $precio); SELECT last_insert_rowid();")
    if [[ -n "$id" ]]; then
        printf "Producto '%s' guardado correctamente con ID %s.\n" "$nombre" "$id"
    else
        printf "Error: no se pudo guardar el producto.\n"
    fi
}

baja_producto() {
    local id
    printf "\nBAJA DE PRODUCTO\n"
    read -rp "Ingrese ID del producto a eliminar: " id

    if ! existe_producto "$id"; then
        printf "Error: No se encontro un producto con el ID '%s'.\n" "$id"
        registrar_error "No se encontro un producto con el ID '$id'."
        return
    fi

    if ejecutar_sql "DELETE FROM productos WHERE id = $id;" >/dev/null; then
        printf "Producto con ID '%s' eliminado correctamente.\n" "$id"
    else
        printf "Error: no se pudo eliminar el producto.\n"
    fi
}

modificar_producto() {
    local id nuevo_nombre nuevo_precio actual nombre_actual precio_actual nombre_sql
    printf "\nMODIFICAR PRODUCTO\n"
    read -rp "Ingrese ID del producto a modificar: " id

    if ! existe_producto "$id"; then
        printf "Error: No se encontro un producto con el ID '%s'.\n" "$id"
        registrar_error "No se encontro un producto con el ID '$id'."
        return
    fi

    actual=$(ejecutar_sql "SELECT nombre || char(9) || precio FROM productos WHERE id = $id;")
    IFS=$'\t' read -r nombre_actual precio_actual <<< "$actual"
    printf "Producto encontrado: [%s] %s - $%s\n" "$id" "$nombre_actual" "$precio_actual"
    read -rp "Ingrese nuevo Nombre (Dejar vacio para mantener '$nombre_actual'): " nuevo_nombre
    read -rp "Ingrese nuevo Precio (Dejar vacio para mantener '$precio_actual'): " nuevo_precio
    [[ -z "$nuevo_nombre" ]] && nuevo_nombre="$nombre_actual"
    [[ -z "$nuevo_precio" ]] && nuevo_precio="$precio_actual"

    if [[ ! "$nuevo_precio" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf "Error: El precio debe ser numerico.\n"
        registrar_error "El precio '$nuevo_precio' no es numerico."
        return
    fi

    nombre_sql=$(sql_escape "$nuevo_nombre")
    if ejecutar_sql "UPDATE productos SET nombre = '$nombre_sql', precio = $nuevo_precio WHERE id = $id;" >/dev/null; then
        printf "Producto ID '%s' modificado correctamente.\n" "$id"
    else
        printf "Error: no se pudo modificar el producto.\n"
    fi
}

mostrar_productos() {
    local filas
    printf "\nLISTADO DE PRODUCTOS\n"
    filas=$(ejecutar_sql "SELECT id || char(9) || nombre || char(9) || printf('%.2f', precio) FROM productos ORDER BY id;")
    if [[ -z "$filas" ]]; then
        printf "El inventario esta vacio.\n"
        return
    fi

    printf "%-10s | %-20s | %-10s\n" "ID" "NOMBRE" "PRECIO"
    printf "%s\n" "..........................................."
    while IFS=$'\t' read -r id nombre precio; do
        printf "%-10s | %-20s | $%-9.2f\n" "$id" "$nombre" "$precio"
    done <<< "$filas"
}

generar_reporte_html() {
    local filas
    filas=$(ejecutar_sql "SELECT id || char(9) || nombre || char(9) || printf('%.2f', precio) FROM productos ORDER BY id;")
    {
        echo "<!DOCTYPE html>"
        echo "<html lang=\"es\"><head><meta charset=\"UTF-8\"><title>Reporte de Productos</title>"
        echo "<style>body { font-family: Arial, sans-serif; margin: 20px; } table { border-collapse: collapse; width: 100%; max-width: 600px; } th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; } th { background-color: #f2f2f2; }</style>"
        echo "</head><body><h2>Reporte Detallado de Productos</h2><table><thead><tr><th>ID</th><th>Nombre</th><th>Precio</th></tr></thead><tbody>"
        while IFS=$'\t' read -r id nombre precio; do
            [[ -n "$id" ]] && printf "<tr><td>%s</td><td>%s</td><td>$%s</td></tr>\n" "$id" "$nombre" "$precio"
        done <<< "$filas"
        echo "</tbody></table></body></html>"
    } > "$ARCHIVO_REPORTE" || {
        registrar_error "No se pudo generar el reporte HTML."
        return
    }
    printf "\nReporte HTML generado exitosamente en '%s'.\n" "productos.html"
}

flujo_principal() {
    local opcion=""
    local autenticado=0
    printf "Bienvenido/a al sistema de gestion\n"

    while (( autenticado == 0 )); do
        printf "\nAUTENTICACION\n1. Iniciar sesion\n2. Registrar usuario\n3. Salir\n"
        read -rp "Seleccione una opcion: " opcion
        registrar_accion "Autenticacion: opcion $opcion"
        case $opcion in
            1) iniciar_sesion && autenticado=1 ;;
            2) registrar_usuario ;;
            3) printf "Saliendo del sistema...\n"; return ;;
            *) printf "Opcion invalida.\n"; registrar_error "Opcion de autenticacion invalida: $opcion." ;;
        esac
    done

    opcion=0
    while [[ "$opcion" != "6" ]]; do
        printf "\nMENU DE ACCIONES\n1. Alta producto\n2. Baja producto\n3. Modificar producto\n4. Mostrar inventario\n5. Generar reporte HTML\n6. Salir\n"
        read -rp "Opcion: " opcion
        registrar_accion "Menu de acciones: opcion $opcion"
        case $opcion in
            1) alta_producto ;;
            2) baja_producto ;;
            3) modificar_producto ;;
            4) mostrar_productos ;;
            5) generar_reporte_html ;;
            6) printf "\nSaliendo del programa...\n" ;;
            *) printf "\nOpcion invalida.\n"; registrar_error "Opcion de acciones invalida: $opcion." ;;
        esac
    done
}

main() {
    inicializar_base_datos || exit 1
    flujo_principal
}

main "$@"