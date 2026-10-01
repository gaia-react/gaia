
def usage_pr_scope($urows; $cost; $N):
  (reduce ((($urows[] | select(.kind == "binding" and (.type == "research" or .type == "declare")
                and (.ref | type) == "string" and $N[.ref] == true)),
            ($urows[] | select(.kind == "segment" and (.key | type) == "string" and $N[.key] == true)))
           | .session_id | tojson) as $s ({}; .[$s] = true)) as $R
  | {segs: [$urows[] | select(.kind == "segment" and $R[.session_id | tojson] == true)],
     bindings: [$urows[] | select(.kind == "binding" and $R[.session_id | tojson] == true)],
     cost: [$cost[] | select($R[.session_id | tojson] == true)]};
