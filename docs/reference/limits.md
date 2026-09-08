# Limits

| | | |
| --- | --- | --- |
| set fields | 64 | Nest the extras in a `struct`, which counts as one field. |
| ids and integers | exact to 2^53 | Past it, carry the value as a `str` or a `buffer`. |
| request timeout | 10 s | Pass a timeout per call. |
| in flight requests | 32768 per namespace | The cap is a leak detector. |
| state budget | 32 KB/s per client | Raise it with a flush budget, or split the traffic. |
| unreliable schema | just under 1 KB | Drop `:unreliable()`, or narrow the codec. Checked at start. |
| one frame | 1 MB | A loop that fires and never flushes. The throw names the size. |
| flush budget | 1024 minimum | Under it throws. |
