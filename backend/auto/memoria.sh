# Uso: dashboardF1-memoria <salida.tsv> ; una fila por minuto (al empezar cada minuto) hasta que se le pare.
# Columnas: hora UTC; procesos cuyo nombre empieza por chrom o headless y la suma de su RSS en MB;
# procesos «node live-99.js» (control positivo); memoria usada y disponible de WSL (free -m).
# Límite: el RSS sumado cuenta dos veces lo compartido entre procesos de Chromium.
out=$1
[ -s "$out" ] || printf 'utc\tchromium_n\tchromium_rss_mb\tlive99_n\tmem_used_mb\tmem_avail_mb\n' > "$out"
while :; do
  now=$(date -u +%FT%T)
  read -r n rss < <(ps -eo rss=,comm= | awk '$2 ~ /^(chrom|headless)/ {n++; s+=$1} END {print n+0, int(s/1024)}')
  l=$(pgrep -fc '^node live-99.js')
  read -r used avail < <(free -m | awk '/^Mem:/ {print $3, $7}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$n" "$rss" "$l" "$used" "$avail" >> "$out"
  s=$(date +%S); sleep $((60 - 10#$s))
done
