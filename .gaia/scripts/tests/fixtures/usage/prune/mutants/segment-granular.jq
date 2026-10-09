
def usage_pr_scope($usage_records; $reference_set):
  (reduce ((($usage_records[] | select(.kind == "binding" and (.type == "research" or .type == "declare" or .type == "close")
                and (.ref | type) == "string" and $reference_set[.ref] == true)),
            ($usage_records[] | select(.kind == "segment" and (.key | type) == "string" and $reference_set[.key] == true)))
           | .session_id | tojson) as $session ({}; .[$session] = true)) as $session_set
  | {segs: [$usage_records[] | select(.kind == "segment" and $session_set[.session_id | tojson] == true
                and (.inherit == true or (.key | type) != "string" or (.key | startswith("branch:") | not) or $reference_set[.key] == true))],
     bindings: [$usage_records[] | select(.kind == "binding" and $session_set[.session_id | tojson] == true)]};
