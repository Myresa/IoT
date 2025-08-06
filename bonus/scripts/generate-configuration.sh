#!/bin/bash

# Usage: ./template_replace.sh templates_dir output_dir key1=value1 key2=value2 ...

templates_dir=$1
output_dir=$2
shift 2

declare -A replacements

for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    replacements[$key]=$value
done

mkdir -p "$output_dir"

# Parcourir tous les fichiers dans le répertoire templates
if [ -d $templates_dir ] ; then
  for template_file in "$templates_dir"/*; do
      filename=$(basename "$template_file")
      output_file="$output_dir/$filename"

      # Lire le contenu du fichier template
      content=$(cat "$template_file")

      # Pour chaque clé dans les substitutions, faire le remplacement {{KEY}} -> valeur
      for key in "${!replacements[@]}"; do
          # Remplace toutes les occurrences de {{KEY}} par la valeur
          content=$(echo "$content" | sed "s/{{${key}}}/${replacements[$key]}/g")
      done

      # Écrire le contenu modifié dans le fichier de sortie
      echo "$content" > "$output_file"
      echo "Generated $output_file"
  done
elif [ -f $templates_dir ] ; then
    filename=$(basename "$templates_dir")
    output_file="$output_dir/$filename"

    # Lire le contenu du fichier template
    content=$(cat "$templates_dir")

    # Pour chaque clé dans les substitutions, faire le remplacement {{KEY}} -> valeur
    for key in "${!replacements[@]}"; do
        # Remplace toutes les occurrences de {{KEY}} par la valeur
        content=$(echo "$content" | sed "s/{{${key}}}/${replacements[$key]}/g")
    done

    # Écrire le contenu modifié dans le fichier de sortie
    echo "$content" > "$output_file"
    echo "Generated $output_file"
fi

