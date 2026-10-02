
def usage_pr_scope($usage_records; $cost; $reference_set):
  (reduce ((($usage_records[] | select(.kind == "binding" and (.type == "research" or .type == "declare")
                and (.ref | type) == "string" and $reference_set[.ref] == true)),
            ($usage_records[] | select(.kind == "segment" and (.key | type) == "string" and $reference_set[.key] == true)),
            ($cost[] | select(usage_row_key(.) as $row_key | $row_key != null and $reference_set[$row_key] == true)))
           | .session_id | tojson) as $session ({}; .[$session] = true)) as $session_set
  | {segs: [$usage_records[] | select(.kind == "segment" and $session_set[.session_id | tojson] == true
                and (.inherit == true or (.key | type) != "string" or (.key | startswith("branch:") | not) or $reference_set[.key] == true))],
     bindings: [$usage_records[] | select(.kind == "binding" and $session_set[.session_id | tojson] == true)],
     cost: [$cost[] | select($session_set[.session_id | tojson] == true)]};
