--!strict

--[=[
	Statistics

	Computes the numbers that a benchmark row reports from its samples: the median, the median
	absolute deviation, a bootstrap interval of the median, and the Tukey outliers.

	The arithmetic is one module on both ends of a run, in Studio and in the terminal, so it uses no
	Roblox global. Its only randomness is the bootstrap, which draws from a RandomSource that the
	caller seeds, so one list of samples and one seed give one interval on every host.

	Nothing here removes a sample: an outlier is flagged and kept.
]=]


-- Imports -----------------------------------------------------------------------------------------

local RandomSource = require("./RandomSource")


-- Module ------------------------------------------------------------------------------------------

local Statistics = {}


-- Types -------------------------------------------------------------------------------------------

type Quantiles = {
	read median:        number,
	read firstQuartile: number,
	read thirdQuartile: number,
	read intervalLow:   number,
	read intervalHigh:  number,
}


type Fences = {
	read mildLow:     number,
	read mildHigh:    number,
	read extremeLow:  number,
	read extremeHigh: number,
}


type FenceFactors = {
	read mild:    number,
	read extreme: number,
}


--[=[
	A range that the median of the samples probably lies in.

	@field low  the lower end of the range
	@field high the upper end of the range
]=]
export type Interval = {
	read low:  number,
	read high: number,
}


--- How far a sample lies outside the middle half of the samples, in Tukey's terms.
export type OutlierKind =
	| "Normal"
	| "Mild"
	| "Extreme"


--[=[
	The numbers of one benchmark row.

	@field sampleCount             how many samples there are
	@field median                  the middle sample, or the mean of the two middle ones
	@field medianAbsoluteDeviation the median of the distances of the samples from the median
	@field firstQuartile           the sample a quarter of the way up the sorted samples
	@field thirdQuartile           the sample three quarters of the way up the sorted samples
	@field interval                the 95% bootstrap interval of the median
	@field outlierKinds            the kind of each sample, in the order the samples came
]=]
export type Summary = {
	read sampleCount:             number,
	read median:                  number,
	read medianAbsoluteDeviation: number,
	read firstQuartile:           number,
	read thirdQuartile:           number,
	read interval:                Interval,
	read outlierKinds:            { OutlierKind },
}


-- Constants ---------------------------------------------------------------------------------------

--- How many times the bootstrap draws a new list of samples from the real ones.
const RESAMPLE_COUNT = 2000


--- The fractions of the sorted samples where the statistics sit; the interval holds 95% of medians.
const QUANTILE: Quantiles = {
	median        = 0.5,
	firstQuartile = 0.25,
	thirdQuartile = 0.75,
	intervalLow   = 0.025,
	intervalHigh  = 0.975,
}


--- How many interquartile ranges beyond a quartile a mild outlier and an extreme outlier lie.
const FENCE_FACTOR: FenceFactors = {
	mild    = 1.5,
	extreme = 3,
}


-- Private -----------------------------------------------------------------------------------------

local function problemWith(samples: { number }): string?
	if #samples == 0 then
		return "samples must hold at least one number, got none"
	end

	for i, sample in samples do
		if not math.isfinite(sample) then
			return `samples must hold only finite numbers, got {sample} at sample {i}`
		end
	end

	return nil
end


local function sortedCopy(samples: { number }): { number }
	local sorted = table.clone(samples)
	table.sort(sorted)

	return sorted
end


--[=[
	Returns the sample that lies `fraction` of the way from the lowest to the highest.

	The place is `(count - 1) * fraction` counted from the lowest sample, which is place 0. A place
	between two samples gives the straight line between them: the lower sample plus the place's
	fraction of the step up to the next, as the "linear" quantile of Hyndman and Fan's type 7 does.

	@param  sorted   the samples in ascending order, at least one
	@param  fraction how far up to read, from 0 for the lowest sample to 1 for the highest
	@return the sample at that place, interpolated when the place is not a whole number
]=]
local function quantileOfSorted(sorted: { number }, fraction: number): number
	local rank       = (#sorted - 1) * fraction
	local lowerRank  = math.floor(rank)
	local lowerIndex = lowerRank + 1
	local upperIndex = math.min(lowerIndex + 1, #sorted)
	local lower      = sorted[lowerIndex]
	local upper      = sorted[upperIndex]

	return lower + (rank - lowerRank) * (upper - lower)
end


local function quantile(samples: { number }, fraction: number): number
	return quantileOfSorted(sortedCopy(samples), fraction)
end


local function median(samples: { number }): number
	return quantile(samples, QUANTILE.median)
end


local function medianAbsoluteDeviation(samples: { number }): number
	local center     = median(samples)
	local deviations = table.create(#samples, 0)
	for i, sample in samples do
		deviations[i] = math.abs(sample - center)
	end

	return median(deviations)
end


local function bootstrapInterval(samples: { number }, seed: number): Interval
	local source      = RandomSource.newUnrecorded(seed)
	local sampleCount = #samples
	local resample    = table.create(sampleCount, 0)
	local medians     = table.create(RESAMPLE_COUNT, 0)
	for i = 1, RESAMPLE_COUNT do
		for j = 1, sampleCount do
			local position = source:drawInteger(1, sampleCount)
			resample[j]    = samples[position]
		end

		medians[i] = median(resample)
	end

	table.sort(medians)

	return {
		low  = quantileOfSorted(medians, QUANTILE.intervalLow),
		high = quantileOfSorted(medians, QUANTILE.intervalHigh),
	}
end


local function fencesOf(samples: { number }): Fences
	local sorted        = sortedCopy(samples)
	local firstQuartile = quantileOfSorted(sorted, QUANTILE.firstQuartile)
	local thirdQuartile = quantileOfSorted(sorted, QUANTILE.thirdQuartile)
	local range         = thirdQuartile - firstQuartile

	return {
		mildLow     = firstQuartile - FENCE_FACTOR.mild * range,
		mildHigh    = thirdQuartile + FENCE_FACTOR.mild * range,
		extremeLow  = firstQuartile - FENCE_FACTOR.extreme * range,
		extremeHigh = thirdQuartile + FENCE_FACTOR.extreme * range,
	}
end


local function kindOf(sample: number, fences: Fences): OutlierKind
	if sample < fences.extremeLow or sample > fences.extremeHigh then
		return "Extreme"
	end

	if sample < fences.mildLow or sample > fences.mildHigh then
		return "Mild"
	end

	return "Normal"
end


local function outlierKinds(samples: { number }): { OutlierKind }
	local fences = fencesOf(samples)
	local kinds  = table.create(#samples) :: { OutlierKind }
	for i, sample in samples do
		kinds[i] = kindOf(sample, fences)
	end

	return kinds
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Computes the 95% bootstrap interval of the median of the samples.

	It draws RESAMPLE_COUNT lists of the same length from the samples, with replacement, takes the
	median of each, and returns the 2.5th and 97.5th percentiles of those medians.

	@param  samples the measurements, at least one, all finite
	@param  seed    the seed of the resampling, a whole number from 0 to 4294967295
	@return the interval, which is the same for the same samples and seed on every host
	@error  when `samples` is empty or holds a number that is not finite
	@error  when `seed` is not a whole number from 0 to 4294967295
]=]
function Statistics.bootstrapInterval(samples: { number }, seed: number): Interval
	local problem = problemWith(samples)
	if problem ~= nil then
		error(problem, 2)
	end

	if not RandomSource.isWord(seed) then
		error(`seed must be a whole number from 0 to {RandomSource.MAX_WORD}, got {seed}`, 2)
	end

	return bootstrapInterval(samples, seed)
end


--[=[
	Computes the median of the samples.

	@param  samples the measurements, at least one, all finite
	@return the middle sample, or the mean of the two middle ones when there is an even number
	@error  when `samples` is empty or holds a number that is not finite
]=]
function Statistics.median(samples: { number }): number
	local problem = problemWith(samples)
	if problem ~= nil then
		error(problem, 2)
	end

	return median(samples)
end


--[=[
	Computes the median absolute deviation of the samples, without scaling it.

	@param  samples the measurements, at least one, all finite
	@return the median of the distances of the samples from their median
	@error  when `samples` is empty or holds a number that is not finite
]=]
function Statistics.medianAbsoluteDeviation(samples: { number }): number
	local problem = problemWith(samples)
	if problem ~= nil then
		error(problem, 2)
	end

	return medianAbsoluteDeviation(samples)
end


--[=[
	Classifies each sample by Tukey's fences, and keeps every sample.

	A sample is a mild outlier beyond 1.5 interquartile ranges below the first quartile or above
	the third, and an extreme one beyond 3. The quartiles are those of `quantile`.

	@param  samples the measurements, at least one, all finite
	@return the kind of each sample, in the order of `samples`
	@error  when `samples` is empty or holds a number that is not finite
]=]
function Statistics.outlierKinds(samples: { number }): { OutlierKind }
	local problem = problemWith(samples)
	if problem ~= nil then
		error(problem, 2)
	end

	return outlierKinds(samples)
end


--[=[
	Computes the sample at a fraction of the way up the sorted samples.

	Between two neighbouring samples the answer is read linearly between them, so 0 gives the
	least sample, 1 the greatest and 0.5 the median.

	@param  samples  the measurements, at least one, all finite
	@param  fraction how far up to read, from 0 to 1
	@return the sample at that fraction
	@error  when `samples` is empty or holds a number that is not finite
	@error  when `fraction` is not a number from 0 to 1
]=]
function Statistics.quantile(samples: { number }, fraction: number): number
	local problem = problemWith(samples)
	if problem ~= nil then
		error(problem, 2)
	end

	if
		not math.isfinite(fraction)
		or fraction < 0
		or fraction > 1
	then
		error(`fraction must be a number from 0 to 1, got {fraction}`, 2)
	end

	return quantile(samples, fraction)
end


--[=[
	Computes the numbers of one benchmark row.

	@param  samples the measurements, at least one, all finite
	@param  seed    the seed of the bootstrap, a whole number from 0 to 4294967295
	@return the median, its spread, its interval and the outlier kinds
	@error  when `samples` is empty or holds a number that is not finite
	@error  when `seed` is not a whole number from 0 to 4294967295
]=]
function Statistics.summarize(samples: { number }, seed: number): Summary
	local problem = problemWith(samples)
	if problem ~= nil then
		error(problem, 2)
	end

	if not RandomSource.isWord(seed) then
		error(`seed must be a whole number from 0 to {RandomSource.MAX_WORD}, got {seed}`, 2)
	end

	return {
		sampleCount             = #samples,
		median                  = median(samples),
		medianAbsoluteDeviation = medianAbsoluteDeviation(samples),
		firstQuartile           = quantile(samples, QUANTILE.firstQuartile),
		thirdQuartile           = quantile(samples, QUANTILE.thirdQuartile),
		interval                = bootstrapInterval(samples, seed),
		outlierKinds            = outlierKinds(samples),
	}
end


return table.freeze(Statistics)
