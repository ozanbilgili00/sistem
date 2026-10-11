import Foundation

/// The scripts a server runs. Fixed text: nothing the user typed is ever part of it, and it is sent on
/// standard input to `sh -s`, so no quoting layer sits between this file and the remote shell.
/// Every line of output starts with a keyword; ``ServerReadingParser`` ignores what it does not know.
/// Commands that do not take a file get `</dev/null`, so none of them can swallow the rest of the script.
public enum ServerScripts {
    public static let version = "SISTEM1"
    public static let end = "END"

    public static func script(for kind: ServerKind) -> String {
        switch kind {
        case .linux: linux
        case .macOS: macOS
        case .docker, .localDocker: docker
        }
    }

    static let linux = """
    echo 'SISTEM1 linux'
    awk '/^cpu /{print "cpu",$2,$3,$4,$5,$6,$7,$8,$9}/^cpu[0-9]/{n++}END{print "cores",n+0}' /proc/stat
    awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{print "mem",t+0,a+0,st+0,sf+0}' /proc/meminfo
    awk '{print "load",$1,$2,$3}' /proc/loadavg
    awk '{print "up",$1}' /proc/uptime
    awk 'NR>2{sub(/:/," ");if($1!="lo"){r+=$2;t+=$10}}END{print "net",r+0,t+0}' /proc/net/dev
    df -kP / </dev/null | awk 'NR==2{print "disk",$2,$3}'
    echo END
    """

    static let macOS = """
    echo 'SISTEM1 macos'
    sysctl -n hw.memsize hw.ncpu </dev/null | awk 'NR==1{print "memsize",$1}NR==2{print "cores",$1}'
    vm_stat </dev/null | awk '/page size of/{p=$8}/^Pages free:/{f=$3}/^Pages active:/{a=$3}/^Pages inactive:/{i=$3}/^Pages speculative:/{s=$3}/^Pages wired down:/{w=$4}/^Pages occupied by compressor:/{c=$5}END{print "vm",p+0,f+0,a+0,i+0,s+0,w+0,c+0}'
    sysctl -n vm.loadavg </dev/null | awk '{print "load",$2,$3,$4}'
    sysctl -n kern.boottime </dev/null | awk '{print "boot",$4+0}'
    echo "now $(date +%s)"
    top -l 2 -n 0 -s 1 </dev/null | awk '/^CPU usage:/{u=$3;s=$5;i=$7}END{print "cpupct",u+0,s+0,i+0}'
    netstat -ib </dev/null | awk '$3 ~ /^<Link/ && $1 !~ /^lo/{r+=$(NF-4);t+=$(NF-1)}END{print "net",r+0,t+0}'
    df -k / </dev/null | awk 'NR==2{print "disk",$2,$3}'
    echo END
    """

    /// The format string is the one thing both the remote script and the local call share.
    static let dockerFormat = "ctr {{.Name}}|{{.CPUPerc}}|{{.MemUsage}}"

    static let docker = """
    echo 'SISTEM1 docker'
    command -v docker >/dev/null 2>&1 || { echo NODOCKER; echo END; exit 0; }
    docker stats --no-stream --format '\(dockerFormat)' </dev/null 2>/dev/null || echo DOCKERFAIL
    echo END
    """

    /// What the reachability check runs remotely: nothing but "answer".
    public static let reachability = "true"
}
