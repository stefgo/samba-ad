#!/bin/bash
#
# Checks that every link into the documentation from the image, the scripts
# and the templates points at a page and anchor that exist in the built site:
#
#   mkdocs build && tests/check-doc-links.sh site

set -euo pipefail

SITE=${1:?usage: $0 <built site directory>}
failed=0

while read -r link; do
  page=${link%%/*}
  file=$SITE/$page/index.html
  if [ ! -f "$file" ]; then
    echo "missing page:   $link"
    failed=1
  elif [[ $link == *#* ]] && ! grep -q "id=\"${link#*#}\"" "$file"; then
    echo "missing anchor: $link"
    failed=1
  fi
done < <(grep -rhoE '(docs:|stefgo\.github\.io/samba-ad/)[a-z-]+/(#[a-z0-9-]+)?' \
    docker init.sh README.md .env.example acme.env.example sadm-config.yaml |
  sed -E 's#^(docs:|stefgo\.github\.io/samba-ad/)##' | sort -u)

if [ $failed == 0 ]; then
  echo "Every link into the documentation resolves."
fi
exit $failed
