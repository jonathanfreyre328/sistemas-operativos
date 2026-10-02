#!/usr/bin/env bash

# Archivos de datos
declare -r ARCHIVO_PRODUCTOS="productos.tsv"
declare -r ARCHIVO_USUARIOS="usuarios.tsv"
declare -r ARCHIVO_REPORTE="productos.html"

# Opciones de menú
declare -r -i OPCION_ALTA=1
declare -r -i OPCION_BAJA=2
declare -r -i OPCION_MODIFICAR=3
declare -r -i OPCION_MOSTRAR=4
declare -r -i OPCION_REPORTAR=5
declare -r -i OPCION_SALIR=6

bienvenida() {
    printf "Bienvenido/a al sistema de gestion\n\n"
}

inicializar_archivos() {
    [[ ! -f "$ARCHIVO_PRODUCTOS" ]] && touch "$ARCHIVO_PRODUCTOS"
    [[ ! -f "$ARCHIVO_USUARIOS" ]] && touch "$ARCHIVO_USUARIOS"
}

obtener_hash() {
    local texto="$1"
    local hash_out
    hash_out=$(printf "%s" "$texto" | sha256sum | cut -d' ' -f1)
    echo "$hash_out"
}

registrar_usuario() {
    local user pass user_file pass_hash
    printf "\n--- REGISTRO DE USUARIO ---\n"
    read -rp "Ingrese nuevo nombre de usuario: " user

    if [[ -z "$user" ]]; then
        printf "El usuario no puede estar vacio.\n"
        return
    fi

    if [[ -f "$ARCHIVO_USUARIOS" ]]; then
        while IFS=$'\t' read -r user_file pass_hash || [[ -n "$user_file" ]]; do
            if [[ "$user_file" == "$user" ]]; then
                printf "Error: El usuario '%s' ya existe.\n" "$user"
                return
            fi
        done < "$ARCHIVO_USUARIOS"
    fi

    read -rsp "Ingrese contraseña: " pass
    printf "\n"

    if [[ -z "$pass" ]]; then
        printf "La contraseña no puede estar vacia.\n"
        return
    fi

    local hash_final
    hash_final=$(obtener_hash "$pass")

    # Guardar credenciales separadas por TAB
    printf "%s\t%s\n" "$user" "$hash_final" >> "$ARCHIVO_USUARIOS"
    printf "Usuario '%s' registrado exitosamente.\n" "$user"
}

iniciar_sesion() {
    local user pass user_file pass_hash
    declare -i intentos=0

    printf "\n--- INICIO DE SESION ---\n"

    if [[ ! -s "$ARCHIVO_USUARIOS" ]]; then
        printf "No hay usuarios registrados en el sistema. Registre uno primero.\n"
        return 1
    fi

    while (( intentos < 3 )); do
        read -rp "Usuario: " user
        read -rsp "Contraseña: " pass
        printf "\n"

        local pass_ingresada_hash
        pass_ingresada_hash=$(obtener_hash "$pass")
        local autenticado=0

        while IFS=$'\t' read -r user_file pass_hash || [[ -n "$user_file" ]]; do
            if [[ "$user_file" == "$user" && "$pass_hash" == "$pass_ingresada_hash" ]]; then
                autenticado=1
                break
            fi
        done < "$ARCHIVO_USUARIOS"

        if (( autenticado == 1 )); then
            printf "Acceso concedido. Bienvenido/a, %s.\n" "$user"
            return 0
        fi

        intentos=$((intentos + 1))
        printf "Credenciales incorrectas (%d/3 intentos).\n" "$intentos"
    done

    return 1
}

menu_autenticacion() {
    local opcion=""
    while true; do
        printf "\n--- AUTENTICACION ---\n"
        printf "1. Iniciar sesion\n"
        printf "2. Registrar usuario\n"
        printf "3. Salir\n"
        read -rp "Seleccione una opcion: " opcion

        case $opcion in
            1)
                if iniciar_sesion; then
                    return 0
                fi
                ;;
            2)
                registrar_usuario
                ;;
            3)
                printf "Saliendo del sistema...\n"
                exit 0
                ;;
            *)
                printf "Opcion invalida.\n"
                ;;
        esac
    done
}

alta_producto() {
    local id nombre precio id_f nom_f prec_f
    printf "\n--- ALTA DE PRODUCTO ---\n"
    read -rp "Ingrese ID del producto: " id
    read -rp "Ingrese Nombre del producto: " nombre
    read -rp "Ingrese Precio del producto: " precio

    if [[ -z "$id" || -z "$nombre" || -z "$precio" ]]; then
        printf "Error: Todos los campos son obligatorios.\n"
        return
    fi

    # Validar si el ID ya existe
    if [[ -f "$ARCHIVO_PRODUCTOS" ]]; then
        while IFS=$'\t' read -r id_f nom_f prec_f || [[ -n "$id_f" ]]; do
            if [[ "$id_f" == "$id" ]]; then
                printf "Error: Ya existe un producto registrado con el ID '%s'.\n" "$id"
                return
            fi
        done < "$ARCHIVO_PRODUCTOS"
    fi

    # Corrección: Tres especificadores %s\t%s\t%s para 3 variables
    printf "%s\t%s\t%s\n" "$id" "$nombre" "$precio" >> "$ARCHIVO_PRODUCTOS"
    printf "Producto '%s' guardado correctamente.\n" "$nombre"
}

baja_producto() {
    local id id_f nom_f prec_f
    local encontrado=0
    printf "\n--- BAJA DE PRODUCTO ---\n"
    read -rp "Ingrese ID del producto a eliminar: " id

    if [[ ! -s "$ARCHIVO_PRODUCTOS" ]]; then
        printf "No hay productos registrados.\n"
        return
    fi

    local temp_file
    temp_file=$(mktemp)

    while IFS=$'\t' read -r id_f nom_f prec_f || [[ -n "$id_f" ]]; do
        if [[ -z "$id_f" ]]; then
            continue
        fi
        if [[ "$id_f" == "$id" ]]; then
            encontrado=1
        else
            printf "%s\t%s\t%s\n" "$id_f" "$nom_f" "$prec_f" >> "$temp_file"
        fi
    done < "$ARCHIVO_PRODUCTOS"

    if (( encontrado == 1 )); then
        mv "$temp_file" "$ARCHIVO_PRODUCTOS"
        printf "Producto con ID '%s' eliminado correctamente.\n" "$id"
    else
        rm -f "$temp_file"
        printf "Error: No se encontro un producto con el ID '%s'.\n" "$id"
    fi
}

modificar_producto() {
    local id nuevo_nombre nuevo_precio id_f nom_f prec_f
    local encontrado=0
    printf "\n--- MODIFICAR PRODUCTO ---\n"
    read -rp "Ingrese ID del producto a modificar: " id

    if [[ ! -s "$ARCHIVO_PRODUCTOS" ]]; then
        printf "No hay productos registrados.\n"
        return
    fi

    local temp_file
    temp_file=$(mktemp)

    # Se usa -u 3 para leer del File Descriptor 3, liberando el teclado
    while IFS=$'\t' read -r -u 3 id_f nom_f prec_f || [[ -n "$id_f" ]]; do
        if [[ -z "$id_f" ]]; then
            continue
        fi
        
        if [[ "$id_f" == "$id" ]]; then
            encontrado=1
            printf "Producto encontrado: [%s] %s - $%s\n" "$id_f" "$nom_f" "$prec_f"
            
            # Ahora este read sí leerá del teclado (stdin)
            read -rp "Ingrese nuevo Nombre (Dejar vacio para mantener '$nom_f'): " nuevo_nombre
            read -rp "Ingrese nuevo Precio (Dejar vacio para mantener '$prec_f'): " nuevo_precio
            
            [[ -z "$nuevo_nombre" ]] && nuevo_nombre="$nom_f"
            [[ -z "$nuevo_precio" ]] && nuevo_precio="$prec_f"

            printf "%s\t%s\t%s\n" "$id_f" "$nuevo_nombre" "$nuevo_precio" >> "$temp_file"
        else
            printf "%s\t%s\t%s\n" "$id_f" "$nom_f" "$prec_f" >> "$temp_file"
        fi
    # El archivo se redirige al File Descriptor 3
    done 3< "$ARCHIVO_PRODUCTOS"

    if (( encontrado == 1 )); then
        mv "$temp_file" "$ARCHIVO_PRODUCTOS"
        printf "Producto ID '%s' modificado correctamente.\n" "$id"
    else
        rm -f "$temp_file"
        printf "Error: No se encontro un producto con el ID '%s'.\n" "$id"
    fi
}

mostrar_productos() {
    local id_f nom_f prec_f
    printf "\n--- LISTADO DE PRODUCTOS ---\n"
    
    if [[ ! -s "$ARCHIVO_PRODUCTOS" ]]; then
        printf "El inventario esta vacio.\n"
        return
    fi

    printf "%-10s | %-20s | %-10s\n" "ID" "NOMBRE" "PRECIO"
    printf "%s\n" "-------------------------------------------"
    
    while IFS=$'\t' read -r id_f nom_f prec_f || [[ -n "$id_f" ]]; do
        if [[ -n "$id_f" ]]; then
            printf "%-10s | %-20s | $%-9.2f\n" "$id_f" "$nom_f" "$prec_f"
        fi
    done < "$ARCHIVO_PRODUCTOS"
}

generar_reporte_html() {
    local id_f nom_f prec_f
    
    {
        echo "<!DOCTYPE html>"
        echo "<html lang=\"es\">"
        echo "<head>"
        echo "    <meta charset=\"UTF-8\">"
        echo "    <title>Reporte de Productos</title>"
        echo "    <style>"
        echo "        body { font-family: Arial, sans-serif; margin: 20px; }"
        echo "        table { border-collapse: collapse; width: 100%; max-width: 600px; }"
        echo "        th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }"
        echo "        th { background-color: #f2f2f2; }"
        echo "    </style>"
        echo "</head>"
        echo "<body>"
        echo "    <h2>Reporte Detallado de Productos</h2>"
        echo "    <table>"
        echo "        <thead>"
        echo "            <tr>"
        echo "                <th>ID</th>"
        echo "                <th>Nombre</th>"
        echo "                <th>Precio</th>"
        echo "            </tr>"
        echo "        </thead>"
        echo "        <tbody>"

        if [[ -s "$ARCHIVO_PRODUCTOS" ]]; then
            while IFS=$'\t' read -r id_f nom_f prec_f || [[ -n "$id_f" ]]; do
                if [[ -n "$id_f" ]]; then
                    printf "            <tr><td>%s</td><td>%s</td><td>$%.2f</td></tr>\n" "$id_f" "$nom_f" "$prec_f"
                fi
            done < "$ARCHIVO_PRODUCTOS"
        fi

        echo "        </tbody>"
        echo "    </table>"
        echo "</body>"
        echo "</html>"
    } > "$ARCHIVO_REPORTE"

    printf "\nReporte HTML generado exitosamente en '%s'.\n" "$ARCHIVO_REPORTE"
}

main() {
    inicializar_archivos
    bienvenida

    menu_autenticacion

    local opcion=0

    while [[ "$opcion" != "$OPCION_SALIR" ]]; do
        printf "\n--- MENU DE ACCIONES ---\n"
        printf "1. Alta producto\n"
        printf "2. Baja producto\n"
        printf "3. Modificar producto\n"
        printf "4. Mostrar inventario\n"
        printf "5. Generar reporte HTML\n"
        printf "6. Salir\n"
        read -rp "Opcion: " opcion

        case $opcion in
            $OPCION_ALTA)
                alta_producto
                ;;
            $OPCION_BAJA)
                baja_producto
                ;;
            $OPCION_MODIFICAR)
                modificar_producto
                ;;
            $OPCION_MOSTRAR)
                mostrar_productos
                ;;
            $OPCION_REPORTAR)
                generar_reporte_html
                ;;
            $OPCION_SALIR)
                printf "\nSaliendo del programa...\n"
                ;;
            *)
                printf "\nOpcion invalida.\n"
                ;;
        esac
    done

    return 0
}

main