-- Deterministic synthetic JSON documents. No external data.
-- Run it with generate.sh. The query parameter `rows` sets the row count (1,000,000 for the full set).
-- The output is one `String` column `s`, one JSON document per row, in Native format.
-- Every value derives from `number` through `cityHash64`, so repeated runs give identical bytes.
--
-- Key words come from a vocabulary of 32 words, so the full set has about 2,000 distinct paths.
-- Planted tokens: `zxneedle` is in an indexed value of 50 adjacent rows (starting at row rows / 2).
-- `zxskipped` is only inside a `_noindex` subtree of 50 adjacent rows (starting at row rows * 0.7).
WITH
    ['alpha','bravo','charlie','delta','echo','foxtrot','golf','hotel','india','juliet','kilo','lima','mike','november','oscar','papa',
     'quebec','romeo','sierra','tango','uniform','victor','whiskey','xray','yankee','zulu','error','timeout','request','session','user','order'] AS words,
    -- word: 3 of 4 from a small vocabulary, 1 of 4 a high-cardinality hex token
    (hw) -> if(hw % 4 = 0, lower(hex(intDiv(hw, 256) % 1048576)), words[1 + intDiv(hw, 7) % 32]) AS word,
    -- kword: key-name word from the small vocabulary, chosen by the position index only (the hash argument is unused); no hex token
    (hk0, ik0) -> words[1 + (ik0 + intDiv(hk0, 7) % 1) % 32] AS kword,
    -- string text of 2..12 words
    (ht) -> arrayStringConcat(arrayMap(j -> word(cityHash64(ht, j)), range(4 + ht % 15)), ' ') AS text,
    -- scalar JSON literal: 45% string, 20% int, 12% float, 10% bool, 13% null
    (hv) -> multiIf(
        hv % 100 < 45, concat('"', text(intDiv(hv, 100)), '"'),
        hv % 100 < 65, toString(intDiv(hv, 100) % 1000000),
        hv % 100 < 77, toString(toFloat64(intDiv(hv, 100) % 10000000) / 1000),
        hv % 100 < 87, if(intDiv(hv, 100) % 2 = 0, 'true', 'false'),
        'null') AS scalar,
    -- scalar key: unique per index i; ~2% contain a literal dot (only at even indexes), ~7% end in _noindex
    (hk, ik) -> multiIf(
        hk % 25 = 0 AND ik % 2 = 0, concat(kword(hk, ik), '.', toString(ik)),
        hk % 14 = 1, concat(kword(hk, ik), '_', toString(ik), '_noindex'),
        concat(kword(hk, ik), '_', toString(ik))) AS skey,
    -- object key: ~25% end in _noindex
    (ho, io) -> concat(kword(ho, io), '_', toString(io), if(ho % 4 = 0, '_noindex', '')) AS okey,
    (hs, ns) -> arrayStringConcat(arrayMap(is -> concat('"', skey(cityHash64(hs, is, 1), is), '":', scalar(cityHash64(hs, is, 2))), range(ns)), ',') AS scalars,
    -- depth-4 (rare) object
    (h3) -> concat('{', scalars(h3, 2 + h3 % 3), '}') AS o3,
    -- depth-3 object (leaves at path depth 3); ~5% of rows contain one depth-4 object
    (h2) -> concat('{', scalars(h2, 4 + h2 % 4), if(h2 % 150 = 0, concat(',"', okey(h2, 70), '":', o3(cityHash64(h2, 4))), ''), '}') AS o2,
    -- depth-1 object: scalars plus 1..3 depth-2 objects
    (h1) -> concat('{', scalars(h1, 4 + h1 % 4), ',',
        arrayStringConcat(arrayMap(i1 -> concat('"', okey(cityHash64(h1, i1, 5), i1 + 30), '":', o2(cityHash64(h1, i1, 6))), range(1 + h1 % 3)), ','), '}') AS o1,
    (ha) -> concat('[', arrayStringConcat(arrayMap(ia -> scalar(cityHash64(ha, ia, 7)), range(3 + ha % 6)), ','), ']') AS arr_scalars,
    (hb) -> concat('[', arrayStringConcat(arrayMap(ib -> concat('{', scalars(cityHash64(hb, ib, 8), 3), '}'), range(2 + hb % 3)), ','), ']') AS arr_objects
SELECT s FROM
(
    SELECT
        number,
        concat('{',
            scalars(cityHash64(number, 100), 14 + number % 8), ',',
            arrayStringConcat(arrayMap(i -> concat('"', okey(cityHash64(number, i, 10), i + 10), '":', o1(cityHash64(number, i, 11))), range(3 + cityHash64(number) % 2)), ','),
            -- ~5% of rows have arrays (scalars and objects)
            if(cityHash64(number, 12) % 20 = 0, concat(',"tags_arr":', arr_scalars(cityHash64(number, 13)), ',"items_arr":', arr_objects(cityHash64(number, 14))), ''),
            -- planted rare tokens: zxneedle in an indexed value (50 adjacent rows), zxskipped only inside a _noindex subtree (50 adjacent rows)
            if(number BETWEEN intDiv({rows:UInt64}, 2) AND intDiv({rows:UInt64}, 2) + 49, ',"note":"error zxneedle timeout"', ''),
            if(number BETWEEN intDiv({rows:UInt64} * 7, 10) AND intDiv({rows:UInt64} * 7, 10) + 49, ',"blob_noindex":{"note":"error zxskipped timeout"}', ''),
        '}') AS s
    FROM numbers({rows:UInt64})
)
ORDER BY number
FORMAT Native
