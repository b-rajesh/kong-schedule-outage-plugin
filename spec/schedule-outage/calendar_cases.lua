-- SPDX-License-Identifier: Apache-2.0
-- Timestamps shared by the schema spec (01) and the calendar spec (06), so the
-- schema and the handler are held to one table and cannot drift apart. Each
-- case is { stamp, valid, why }: `valid` is true when the stamp is a time that
-- exists, written YYYY-MM-DDTHH:MM:SSZ (UTC, proleptic Gregorian, no leap
-- seconds). The verdicts come from the calendar, not from either implementation.
-- Not a spec itself: the name does not end in _spec, so busted does not run it.

local cases, seen = {}, {}

local function add(stamp, valid, why)
  local earlier = seen[stamp]
  if earlier then
    -- Two generators may reach the same stamp, never with different verdicts.
    assert(earlier[2] == valid, "conflicting verdicts for " .. stamp)
    return
  end
  seen[stamp] = { stamp, valid, why }
  cases[#cases + 1] = seen[stamp]
end

local function date(year, month, day, time)
  return string.format("%04d-%02d-%02dT%s", year, month, day, time or "00:00:00Z")
end

local ESCAPES = { ["\n"] = "\\n", ["\r"] = "\\r", ["\0"] = "\\0" }

--- A stamp as it can be written in a test name: control characters escaped.
function cases.show(stamp)
  return (stamp:gsub("%c", function(c)
    return ESCAPES[c] or string.format("\\%d", c:byte())
  end))
end

-- 29 February in every year 2000 to 2099: each tens digit with each units digit.
-- A leap year is divisible by 4 (2000 is a century divisible by 400).
for year = 2000, 2099 do
  local leap = year % 4 == 0
  add(date(year, 2, 29), leap, leap and "leap year" or "year not divisible by 4")
end

-- 29 February in every century year, 0000 to 9900: a leap year only when the
-- year is divisible by 400, that is, when its first two digits are divisible by 4.
for century = 0, 99 do
  local leap = century % 4 == 0
  add(date(century * 100, 2, 29), leap,
      leap and "century year divisible by 400" or "century year not divisible by 400")
end

add(date(1, 2, 29), false, "year 0001, not divisible by 4")
add(date(4, 2, 29), true, "year 0004, divisible by 4")
add(date(9999, 2, 29), false, "year 9999, not divisible by 4")

-- The first day, the last day and the day after it, for every month of a
-- non-leap (2026) and a leap (2024) year.
local MONTHS = {
  { "January", 31 }, { "February", 28 }, { "March", 31 }, { "April", 30 },
  { "May", 31 }, { "June", 30 }, { "July", 31 }, { "August", 31 },
  { "September", 30 }, { "October", 31 }, { "November", 30 }, { "December", 31 },
}
for _, year in ipairs({ 2026, 2024 }) do
  for month, m in ipairs(MONTHS) do
    local name, last = m[1] .. " " .. year, m[2]
    if month == 2 and year == 2024 then
      last = 29
    end
    add(date(year, month, 1), true, "first day of " .. name)
    add(date(year, month, last, "23:59:59Z"), true, "last day of " .. name)
    add(date(year, month, last + 1), false, "day after the last day of " .. name)
  end
end

-- Month, day, hour, minute and second numbers at both ends of each tens block
-- and just past their ranges. The schema's character classes admit months up
-- to 19, days up to 39 and hours up to 29, and further rules remove the
-- impossible ones; minutes and seconds stop at 59 in the pattern itself.
local function numbered(valid, label, build, numbers)
  for _, n in ipairs(numbers) do
    add(build(n), valid, string.format("%s %02d", label, n))
  end
end

local function in_month(n) return date(2026, n, 15) end
local function in_january(n) return date(2026, 1, n) end
local function at(time) return function(n) return date(2026, 12, 1, string.format(time, n)) end end

local EDGES = { 0, 9, 10, 19, 20, 29, 30, 39, 40, 49, 50, 59 }
local BEYOND = { 60, 61, 69, 70, 99 }

numbered(true, "month", in_month, { 1, 9, 10, 12 })
numbered(false, "month", in_month, { 0, 13, 19, 20, 99 })
numbered(true, "day", in_january, { 1, 9, 10, 19, 20, 29, 30, 31 })
numbered(false, "day", in_january, { 0, 32, 39, 40, 99 })
numbered(true, "hour", at("%02d:00:00Z"), { 0, 9, 10, 19, 20, 23 })
numbered(false, "hour", at("%02d:00:00Z"), { 24, 25, 29, 30, 39, 99 })
numbered(true, "minute", at("00:%02d:00Z"), EDGES)
numbered(false, "minute", at("00:%02d:00Z"), BEYOND)
numbered(true, "second", at("00:00:%02dZ"), EDGES)
numbered(false, "second", at("00:00:%02dZ"), BEYOND)

-- February never has 30 or 31 days, not even in a leap year (2024).
add(date(2026, 2, 30), false, "30 February")
add(date(2026, 2, 31), false, "31 February")
add(date(2024, 2, 31), false, "31 February of a leap year")

add("2016-12-31T23:59:60Z", false, "a real leap second: not accepted")
add("2026-13-45T25:61:61Z", false, "every field out of range")
add("0000-01-01T00:00:00Z", true, "first second of year 0000")
add("2026-12-01T02:00:00Z", true, "an ordinary timestamp")
add("2026-12-31T23:59:59Z", true, "last second of 2026")
add("9999-12-31T23:59:59Z", true, "last second of year 9999")

-- Text that is not a timestamp of this exact form, each spoiled in one way.
for _, case in ipairs({
  { "2026-12-01 02:00:00Z", "space instead of T" },
  { "2026-12-01t02:00:00Z", "lowercase t" },
  { "2026-12-01T02:00:00z", "lowercase z" },
  { "2026-12-01T02:00:00", "missing Z" },
  { "2026-12-01T02:00:00+10:00", "offset" },
  { "2026-12-01T02:00:00-05:00", "negative offset" },
  { "2026-12-01T02:00:00+00:00", "zero offset instead of Z" },
  { "2026-12-01T02:00:00.123Z", "fractional seconds" },
  { "2026-12-01T02:00:00.0Z", "zero fractional seconds" },
  { "2026-12-01T02:00:00Z\n", "trailing newline" },
  { "\n2026-12-01T02:00:00Z", "leading newline" },
  { "2026-12-01T02:00:00Z\r\n", "trailing CR LF" },
  { " 2026-12-01T02:00:00Z", "leading space" },
  { "2026-12-01T02:00:00Z ", "trailing space" },
  { "2026-12-01T02:00:00Z\0", "trailing NUL" },
  { "2026-12-01T02:00:0\0Z", "embedded NUL" },
  { "2026-12-01T02:00:00ZZ", "doubled Z" },
  { "2026-12-01T02:00:00Z2026-12-01T02:00:00Z", "two timestamps" },
  { "", "empty" },
  { "2026-12-01", "date only" },
  { "2026-12-01T02:00Z", "no seconds" },
  { "2026/12/01T02:00:00Z", "slashes in the date" },
  { "2026-12-01T02-00-00Z", "dashes in the time" },
  { "26-12-01T02:00:00Z", "two digit year" },
  { "12026-12-01T02:00:00Z", "five digit year" },
  { "2026-1-01T02:00:00Z", "one digit month" },
  { "2026-12-1T02:00:00Z", "one digit day" },
  { "2026-12-01T2:00:00Z", "one digit hour" },
  { "2026-12-0aT02:00:00Z", "letter in the date" },
  { "01/12/2026", "another date format" },
}) do
  add(case[1], false, case[2])
end

return cases
