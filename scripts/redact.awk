# POSIX awk. Only sanitized output leaves this process; no raw log is written.
function sensitive(name) {
    return tolower(name) ~ /(password|passwd|pwd|token|secret|credential|authorization|auth|key)/
}
function add_secret(value,    parts,n,i) {
    if (value == "" || seen[value]++) return
    secrets[++secret_count] = value
    n = split(value, parts, "\n")
    if (n > 1) for (i=1; i<=n; i++) if (parts[i] != "") add_secret(parts[i])
}
function json_escape(value,    i,c,out) {
    out = ""
    for (i=1; i<=length(value); i++) {
        c=substr(value,i,1)
        if (c=="\\") out=out "\\\\"
        else if (c=="\"") out=out "\\\""
        else if (c=="\n") out=out "\\n"
        else if (c=="\r") out=out "\\r"
        else if (c=="\t") out=out "\\t"
        else out=out c
    }
    return out
}
function literal_replace(text, needle, protect_fields,    pos,out,before,tail,word,suffix,keep) {
    out=""
    while ((pos=index(text,needle)) > 0) {
        before=substr(text,1,pos-1); tail=substr(text,pos+length(needle)); keep=0
        # Do not destroy a field/flag name before structured redaction, even
        # if a weak environment password is itself a word such as "token".
        if (protect_fields && needle ~ /^[[:alnum:]_.-]+$/) {
            match(before,/[[:alnum:]_.-]+$/)
            word=substr(before,RSTART,RLENGTH) needle
            match(tail,/^[[:alnum:]_.-]*/)
            word=word substr(tail,1,RLENGTH); suffix=substr(tail,RLENGTH+1)
            if (sensitive(word) && suffix ~ /^[\\"\047]*([[:space:]]*[:=,]|[[:space:]]+)/) keep=1
        }
        out=out before (keep ? needle : "[REDACTED]")
        text=tail
    }
    return out text
}
# Return the closing quote's position, or zero. Escaped mode handles JSON
# strings inside Ansible's stdout/stderr strings (e.g. \"token\": \"...\").
function quote_end(text, quote, escaped, start,    i,c,slashes,j) {
    for (i=start; i<=length(text); i++) {
        c=substr(text,i,1)
        if (c != quote) continue
        slashes=0
        for (j=i-1; j>0 && substr(text,j,1)=="\\"; j--) slashes++
        if ((!escaped && slashes%2==0) || (escaped && slashes%4==1)) return i
    }
    return 0
}
function container_end(text, start,    i,c,pos) {
    for (i=start; i<=length(text); i++) {
        c=substr(text,i,1)
        if (container_quote) {
            pos=quote_end(text,container_quote,container_quote_escaped,i)
            if (!pos) return 0
            container_quote=""; i=pos
        } else if (c=="\"" || c=="\047" || substr(text,i,2)=="\\\"") {
            container_quote_escaped=(c=="\\")
            container_quote=container_quote_escaped ? "\"" : c
            pos=quote_end(text,container_quote,container_quote_escaped,i+1+container_quote_escaped)
            if (!pos) return 0
            container_quote=""; i=pos
        } else if (c=="{" || c=="[") container_depth++
        else if (c=="}" || c=="]") {
            container_depth--
            if (container_depth==0) return i
        }
    }
    return 0
}
function value_end(text,    first,pos,start,escaped,auth_prefix,k) {
    for (k=1; k<=secret_count; k++) {
        if (substr(text,1,length(secrets[k]))==secrets[k]) return length(secrets[k])
    }
    first=substr(text,1,1)
    if (first=="|" || first==">") { yaml_block=1; return length(text) }
    if (first=="{" || first=="[") {
        container_depth=0; container_quote=""; container_escape=0
        pos=container_end(text,1)
        return pos ? pos : length(text)
    }
    escaped=(substr(text,1,2)=="\\\"")
    if (first=="\"" || first=="\047" || escaped) {
        if (escaped) { first="\""; start=3 } else start=2
        pos=quote_end(text,first,escaped,start)
        if (!pos) { block_quote=first; block_escaped=escaped }
        return pos ? pos : length(text)
    }
    auth_prefix=0
    if (match(tolower(text),/^(bearer|basic)[[:space:]]+/)) auth_prefix=RLENGTH
    if (match(substr(text,auth_prefix+1),/^[^[:space:],;}&\]]+/)) return auth_prefix+RLENGTH
    return length(text)
}
function fields(text,    rest,out,pos,n,prefix,tail,consumed,before) {
    rest=text; out=""
    while (match(tolower(rest), /[[:alnum:]_.-]*(password|passwd|pwd|token|secret|credential|authorization|auth|key)[[:alnum:]_.-]*[\\"\047]*([[:space:]]*[:=][[:space:]]*|[[:space:]]*,[[:space:]]*|[[:space:]]+)/)) {
        pos=RSTART; n=RLENGTH
        before=substr(rest,1,pos-1)
        prefix=substr(rest,pos,n)
        tail=substr(rest,pos+n)
        if (tail=="") {
            pending_value=1
            return out before prefix "[REDACTED]"
        }
        consumed=value_end(tail)
        out=out before prefix "[REDACTED]"
        rest=substr(tail,consumed+1)
    }
    return out rest
}
function urls(text,    part,pos,n,scheme,out) {
    out=""
    while (match(tolower(text),/[a-z][a-z0-9+.-]*:[^[:space:]"<>]*@/)) {
        pos=RSTART; n=RLENGTH; part=substr(text,pos,n)
        scheme=index(part,"://")
        out=out substr(text,1,pos-1) (scheme ? substr(part,1,scheme+2) : "") "[REDACTED]@"
        text=substr(text,pos+n)
    }
    return out text
}
function standard_tokens(text,    out,pos,n,part,lead) {
    out=""
    while (match(text,/(^|[^[:alnum:]_-])(gh[pousr]_|github_pat_|sk[-_])[[:alnum:]_-]+/)) {
        pos=RSTART; n=RLENGTH; part=substr(text,pos,n)
        lead=(substr(part,1,1) ~ /[^[:alnum:]_-]/) ? substr(part,1,1) : ""
        out=out substr(text,1,pos-1) lead "[REDACTED]"; text=substr(text,pos+n)
    }
    text=out text; out=""
    while (match(tolower(text),/(^|[^[:alnum:]_-])(bearer|basic)[[:space:]]+[[:alnum:]_+\/.=-]+/)) {
        pos=RSTART; n=RLENGTH; part=substr(text,pos,n)
        lead=(substr(part,1,1) ~ /[^[:alnum:]_-]/) ? substr(part,1,1) : ""
        out=out substr(text,1,pos-1) lead "[REDACTED]"; text=substr(text,pos+n)
    }
    return out text
}
BEGIN {
    secret_count=0
    for (name in ENVIRON) if (sensitive(name)) {
        add_secret(ENVIRON[name])
        add_secret(json_escape(ENVIRON[name]))
    }
    # Replace longer secrets before prefixes of those secrets.
    for (i=1; i<=secret_count; i++) for (j=i+1; j<=secret_count; j++) {
        if (length(secrets[j])>length(secrets[i])) {
            swap=secrets[i]; secrets[i]=secrets[j]; secrets[j]=swap
        }
    }

}
{
    text=$0
    # Remove terminal escapes before matching fields, not after matching.
    gsub(/\033\[[0-9;]*[[:alpha:]]/,"",text)
    if (pem_block || text ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) {
        pem_block=(text !~ /-----END [A-Z ]*PRIVATE KEY-----/)
        print "[REDACTED private key]"; fflush(); next
    }
    if (yaml_block) {
        match(text,/^[[:space:]]*/)
        if (text=="" || RLENGTH>yaml_indent) { print "[REDACTED]"; fflush(); next }
        yaml_block=0
    }
    if (container_depth>0) {
        pos=container_end(text,1)
        if (!pos) { print "[REDACTED]"; fflush(); next }
        text="[REDACTED]" substr(text,pos+1)
    }
    if (block_quote!="") {
        pos=quote_end(text,block_quote,block_escaped,1)
        if (!pos) { print "[REDACTED]"; fflush(); next }
        block_quote=""
        text="[REDACTED]" substr(text,pos+1)
    }
    if (pending_value && text !~ /^[[:space:]]*$/) {
        pending_value=0
        print "[REDACTED]"; fflush(); next
    }
    match(text,/^[[:space:]]*/); yaml_indent=RLENGTH
    for (i=1; i<=secret_count; i++) text=literal_replace(text,secrets[i],1)
    text=fields(text)
    text=urls(text)
    gsub(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,"[REDACTED]",text)
    text=standard_tokens(text)
    gsub(/(AKIA|ASIA)[A-Z0-9]+/,"[REDACTED]",text)
    for (i=1; i<=secret_count; i++) text=literal_replace(text,secrets[i])
    print text; fflush()
}
