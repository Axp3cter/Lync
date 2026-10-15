--!strict
-- v5-checks.md §8.6's AtomSample types `vector` as `vector?`; the samples hold a decoded vector series value.
export type AtomSample = { sinceTriggerSeconds: number, frameKey: number, yaw: number?, pitch: number?, value: number?, vector: vector? }
local fromVector3: AtomSample = { sinceTriggerSeconds = 0, frameKey = 1, vector = Vector3.new(1, 2, 3) }
local s: AtomSample = fromVector3
if s.vector then
	print(s.vector.Magnitude)
end
