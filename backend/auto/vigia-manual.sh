# Uso: dashboardF1-vigia-manual <puerto> <fichero> <carpeta>
# Cada minuto, una línea en <fichero> con lo que contesta /api/live de ese puerto (en hora UTC) y el
# código de OpenF1, y el cuerpo en <carpeta>/<hhmmss>.json, hasta que se le pare.
port=$1
out=$2
dir=$3
mkdir -p "$dir"
while true; do
  h=$(mktemp); b=$(mktemp)
  t=$(curl -s --max-time 60 -D "$h" -o "$b" -w "%{time_total}" "http://localhost:$port/api/live")
  o=$(grep -i "^x-data-origin" "$h" | tr -d "\r" | cut -d" " -f2)
  s=$(grep -i "^x-data-source" "$h" | tr -d "\r" | cut -d" " -f2)
  f=$(grep -i "^x-data-fetched-at" "$h" | tr -d "\r" | cut -d" " -f2)
  n=$(grep -o "\"siName\":\"[^\"]*\"" "$b" | cut -d\" -f4)
  e=$(grep -o "\"srState\":\"[^\"]*\"" "$b" | cut -d\" -f4)
  v=$(grep -o "\"lpCurrent\":[0-9]*" "$b" | cut -d: -f2)
  r=$(grep -o "\"ltPosition\"" "$b" | wc -l)
  k=$(curl -s -o /dev/null --max-time 20 -w "%{http_code}" "https://api.openf1.org/v1/sessions?session_key=latest")
  now=$(date -u +%H:%M:%S)
  printf "%s live=%s/%s fetched=%s sesion=%s estado=%s vuelta=%s filas=%s t=%ss openf1=%s\n" \
    "$now" "${o:--}" "${s:--}" "${f:--}" "${n:--}" "${e:--}" "${v:--}" "$r" "$t" "$k" >> "$out"
  cp "$b" "$dir/${now//:/}.json"
  rm -f "$h" "$b"; sleep 60
done
