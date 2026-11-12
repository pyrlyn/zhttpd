set -eu
root=/home/listepo.guest/zhttpd-perf-h3-throughput
cd "$root/candidate"
for spec in '3 small.html 4' '3 large.bin 4' '2 large.bin 4'; do
 read -r protocol file clients <<< "$spec"
 tag="h$protocol-${file%.*}"
 taskset -c 0 "$root/baseline/bin/zhttpd" -p "$PWD/bench/run/zhttpd/" -c "$PWD/bench/profile.conf" -q > "$root/$tag-server.log" 2>&1 & srv=$!
 trap 'kill -TERM "$srv" 2>/dev/null || true; wait "$srv" || true' EXIT
 sleep 1
 worker=$(pgrep -P "$srv" | head -1)
 sudo perf record -o "$root/$tag.perf" -F 199 -e cpu-clock --call-graph dwarf,16384 -p "$worker" -- sleep 12 > "$root/$tag-perf.log" 2>&1 & profiler=$!
 taskset -c 1-7 /home/listepo.guest/zhttpd-perf-h2-h3/oha-drain/bin/oha --http-version "$protocol" --insecure -z 10s -c "$clients" -p 16 -w --no-tui --output-format json "https://127.0.0.1:29443/static/$file" > "$root/$tag-load.json"
 wait "$profiler"
 sudo perf report -i "$root/$tag.perf" --stdio --no-children --call-graph none --percent-limit .5 > "$root/$tag-flat.txt"
 sudo perf report -i "$root/$tag.perf" --stdio --children --call-graph none --percent-limit 2 > "$root/$tag-children.txt"
 kill -TERM "$srv"; wait "$srv" || true
 trap - EXIT
 head -40 "$root/$tag-children.txt"
done
