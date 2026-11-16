# Profile for the synthetic data set made by generated/generate.sh.
# Skip every key that ends in `_noindex`. Tables C and D have no SKIP REGEXP.
RE='.*_noindex$'
JT_C="JSON"
JT_D="JSON(max_dynamic_paths = 0)"
# role=token. `zxneedle` is in an indexed value. `zxskipped` is only inside a `_noindex` subtree.
TOKENS=(needle=zxneedle skipped=zxskipped)

# Extra function case: the same result with existing functions only, nested to path depth 3.
# Strings keep their JSON quotes, an array stays one raw value, a depth-4 object is one raw value.
extra_function_cases()
{
    local f1 f2 f3 lvl3 lvl2
    f1="arrayFilter(t1 -> NOT endsWith(t1.1, '_noindex') AND t1.2 != 'null', JSONExtractKeysAndValuesRaw(s))"
    f2="arrayFilter(t2 -> NOT endsWith(t2.1, '_noindex') AND t2.2 != 'null', JSONExtractKeysAndValuesRaw(kv1.2))"
    f3="arrayFilter(t3 -> NOT endsWith(t3.1, '_noindex') AND t3.2 != 'null', JSONExtractKeysAndValuesRaw(kv2.2))"
    lvl3="arrayMap(kv3 -> kv3.2, $f3)"
    lvl2="arrayFlatten(arrayMap(kv2 -> if(startsWith(kv2.2, '{'), $lvl3, [kv2.2]), $f2))"
    add "nested JSONExtractKeysAndValuesRaw (depth 3)" \
        "length(arrayFlatten(arrayMap(kv1 -> if(startsWith(kv1.2, '{'), $lvl2, [kv1.2]), $f1)))"
}
