# Limits

The hard limits, what happens when one is reached, and how to stay under it.

| Limit | Value | At the limit | Instead |
| --- | --- | --- | --- |
| Fields per set | 64 | Throws at start. | Nest the extras in a `struct`, which counts as one field. |
| Ids and integers | Exact to 2^53 | Throws. | Carry the value as a `str` or a `buffer`. |
| Request timeout | 10 s default | The request ends `timeout`. | Pass a timeout per call. |
| Requests in flight | 32768 per namespace | Throws on the next request. | Reaching this means requests are being created without completing. Look for a request loop with no timeout handling. |
| State budget | 32 KB/s per client | Remaining state is sent in later flushes. | Pass a larger budget to `flush`, or split the traffic across namespaces. |
| Flush budget floor | 1024 bytes | Throws. | Pass 1024 or more. |
| Unreliable payload | Just under 1 KB | Throws at start. | Drop `:unreliable()`, or narrow the codec. |
| One fire | 1 MB | A flush larger than this is sent as several fires, in order. | A single payload larger than this throws. Reduce the codec's bounds. |
