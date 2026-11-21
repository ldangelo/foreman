#!/bin/sh
# Stand-in `docker` for the network-policy and docker-sandbox tests. Copy it to <dir>/docker (the tests
# do) and pass that path as the `:binary`: it keeps the little daemon state it needs in <dir>/fake/ and
# gives the commands Foreman issues their real semantics where the tests depend on them:
#
#   * `network rm` of a network that still has a container attached fails like the daemon does
#     ("has active endpoints"): a sandbox that outlived its jobsite leaves its network behind;
#   * labels are stored with the object and `--filter label=k[=v]`, `network=`, `name=` and `id=`
#     select by them (AND over repeated filters), so a sweep can only touch what it asked for;
#   * `docker exec` runs the command on THIS host with the container's own `-e` environment, then the
#     exec's `-e` and `--env-file` on top, in the host directory the container's `-v` mounts at `-w`;
#   * `run` prints the new container's id; a container exists until `rm -f` removes it.
#
# Every invocation is appended to calls.log (arguments joined by a space, a newline inside an argument
# shown as `~`) and to argv.log (an `--invocation--` line, then one argument per line).
# A `fail-<arg1>-<arg2>` file beside this script makes that subcommand exit 1 without doing anything.
# State is plain files (fake/net/<name>, fake/ctr/<id>: `key=value` lines `name`, `net` (one per
# attachment), `label`, `env`, `mount`), so a test can also place objects the code under test did
# not create by writing them.

d=$(dirname "$0")
s="$d/fake"
mkdir -p "$s/net" "$s/ctr"

printf '%s' "$*" | tr '\n' '~' >> "$d/calls.log"
echo >> "$d/calls.log"
{
  echo "--invocation--"
  for arg in "$@"; do printf '%s' "$arg" | tr '\n' '~'; echo; done
} >> "$d/argv.log"

if [ -f "$d/fail-$1-$2" ]; then
  echo "fake docker: $1 $2 refused" >&2
  exit 1
fi

die() { echo "$*" >&2; exit 1; }

net_exists() {
  case "$1" in bridge | host | none) return 0 ;; esac
  [ -f "$s/net/$1" ]
}

# attached <network>: the ids of the containers attached to it
attached() {
  for f in "$s"/ctr/*; do
    [ -f "$f" ] || continue
    if grep -qFx "net=$1" "$f"; then basename "$f"; fi
  done
}

# resolve <id or name>: prints the id of that container, or fails
resolve() {
  for f in "$s"/ctr/*; do
    [ -f "$f" ] || continue
    if [ "$(basename "$f")" = "$1" ] || grep -qFx "name=$1" "$f"; then basename "$f"; return 0; fi
  done
  return 1
}

# matches <state file> [filter ...]: 0 when every filter selects the object
matches() {
  m_file=$1; shift
  for flt in "$@"; do
    case "$flt" in
      label=*)
        lbl=${flt#label=}
        case "$lbl" in
          *=*) grep -qFx "label=$lbl" "$m_file" || return 1 ;;
          *) grep -q "^label=$lbl=" "$m_file" || return 1 ;;
        esac ;;
      network=*) grep -qFx "net=${flt#network=}" "$m_file" || return 1 ;;
      name=*)
        case "$(sed -n 's/^name=//p' "$m_file")" in *"${flt#name=}"*) ;; *) return 1 ;; esac ;;
      id=*) [ "$(basename "$m_file")" = "${flt#id=}" ] || return 1 ;;
    esac
  done
  return 0
}

case "$1" in
  image | build | cp) exit 0 ;;

  network)
    shift
    sub=$1; shift
    case "$sub" in
      create)
        tmp="$s/.tmp.$$"; : > "$tmp"
        internal=0
        while [ $# -gt 1 ]; do
          case "$1" in
            --internal) internal=1; shift ;;
            --label) printf 'label=%s\n' "$2" >> "$tmp"; shift 2 ;;
            *) shift ;;
          esac
        done
        name=$1
        if [ -f "$s/net/$name" ]; then
          rm -f "$tmp"
          die "Error response from daemon: network with name $name already exists"
        fi
        { echo "name=$name"; if [ "$internal" = 1 ]; then echo internal; fi; cat "$tmp"; } > "$s/net/$name"
        rm -f "$tmp"
        echo "net-$name"
        ;;
      ls)
        filters=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --filter) filters="$filters $2"; shift 2 ;;
            --format | -f) shift 2 ;;
            *) shift ;;
          esac
        done
        for f in "$s"/net/*; do
          [ -f "$f" ] || continue
          # shellcheck disable=SC2086
          if matches "$f" $filters; then basename "$f"; fi
        done
        ;;
      rm)
        name=$1
        [ -f "$s/net/$name" ] || die "Error response from daemon: network $name not found"
        a=$(attached "$name" | head -n 1)
        [ -z "$a" ] || die "Error response from daemon: error while removing network: network $name id net-$name has active endpoints (name:\"$a\")"
        rm -f "$s/net/$name"
        echo "$name"
        ;;
      connect)
        c=$(resolve "$2") || die "Error response from daemon: No such container: $2"
        net_exists "$1" || die "Error response from daemon: network $1 not found"
        echo "net=$1" >> "$s/ctr/$c"
        ;;
      *) exit 0 ;;
    esac
    ;;

  run)
    shift
    name=""; net=bridge
    tmp="$s/.tmp.$$"; : > "$tmp"
    while [ $# -gt 0 ]; do
      case "$1" in
        -d | --rm | -i | -t) shift ;;
        --name) name=$2; shift 2 ;;
        --network) net=$2; shift 2 ;;
        --label) printf 'label=%s\n' "$2" >> "$tmp"; shift 2 ;;
        -e) printf 'env=%s\n' "$2" >> "$tmp"; shift 2 ;;
        -v) printf 'mount=%s\n' "$2" >> "$tmp"; shift 2 ;;
        -w | -u | --user | --workdir | --env-file) shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    if ! net_exists "$net"; then
      rm -f "$tmp"
      die "docker: Error response from daemon: network $net not found."
    fi
    n=$(cat "$s/seq" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$s/seq"
    id="fake-container-$n"
    [ -n "$name" ] || name="fake-name-$n"
    { echo "name=$name"; echo "image=$1"; echo "net=$net"; cat "$tmp"; } > "$s/ctr/$id"
    rm -f "$tmp"
    echo "$id"
    ;;

  ps)
    shift
    filters=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --filter) filters="$filters $2"; shift 2 ;;
        *) shift ;;
      esac
    done
    for f in "$s"/ctr/*; do
      [ -f "$f" ] || continue
      # shellcheck disable=SC2086
      if matches "$f" $filters; then basename "$f"; fi
    done
    ;;

  rm)
    shift
    rc=0
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      if c=$(resolve "$a"); then
        rm -f "$s/ctr/$c"
      else
        echo "Error response from daemon: No such container: $a" >&2
        rc=1
      fi
    done
    exit $rc
    ;;

  exec)
    shift
    cwd=""
    envf="$s/.env.$$"; : > "$envf"
    while [ $# -gt 0 ]; do
      case "$1" in
        -i | -t) shift ;;
        -w) cwd=$2; shift 2 ;;
        -u) shift 2 ;;
        -e) printf '%s\n' "$2" >> "$envf"; shift 2 ;;
        --env-file) cat "$2" >> "$envf"; shift 2 ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    if ! c=$(resolve "$1"); then
      rm -f "$envf"
      die "Error response from daemon: No such container: $1"
    fi
    shift
    # the container's own environment first: the exec's -e and --env-file override it. Like a
    # container the command gets ONLY that (and a PATH), never the environment of this host.
    { sed -n 's/^env=//p' "$s/ctr/$c"; cat "$envf"; } > "$envf.all"
    assignments=""
    while IFS= read -r kv; do
      if [ -n "$kv" ]; then
        q=$(printf '%s' "$kv" | sed "s/'/'\\\\''/g")
        assignments="$assignments '$q'"
      fi
    done < "$envf.all"
    rm -f "$envf" "$envf.all"
    if [ -n "$cwd" ]; then
      for m in $(sed -n 's/^mount=//p' "$s/ctr/$c"); do
        host=${m%%:*}
        rest=${m#*:}
        cont=${rest%%:*}
        if [ "$cont" = "$cwd" ]; then cd "$host" || exit 1; fi
      done
    fi
    eval "exec env -i PATH=\"\$PATH\" $assignments \"\$@\""
    ;;

  *) exit 0 ;;
esac
