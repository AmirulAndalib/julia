# This file is a part of Julia. License is MIT: https://julialang.org/license

#Period types
"""
    Dates.value(x::Period)::Int64

For a given period, return the value associated with that period.  For example,
`value(Millisecond(10))` returns 10 as an integer.
"""
value(x::Period) = x.value

# The default constructors for Periods work well in almost all cases
# P(x) = new((convert(Int64,x))
# The following definitions are for Period-specific safety
for period in (:Year, :Quarter, :Month, :Week, :Day, :Hour, :Minute, :Second, :Millisecond, :Microsecond, :Nanosecond)
    period_str = string(period)
    accessor_str = lowercase(period_str)
    # Convenience method for show()
    @eval _units(x::$period) = " " * $accessor_str * (abs(value(x)) == 1 ? "" : "s")
    # AbstractString parsing (mainly for IO code)
    @eval $period(x::AbstractString) = $period(Base.parse(Int64, x))
    # The period type is printed when output, thus it already implies its own typeinfo
    @eval Base.typeinfo_implicit(::Type{$period}) = true
    # Period accessors
    typs = period in (:Microsecond, :Nanosecond) ? ["Time"] :
           period in (:Hour, :Minute, :Second, :Millisecond) ? ["Time", "DateTime"] : ["Date", "DateTime"]
    reference = period === :Week ? " For details see [`$accessor_str(::Union{Date, DateTime})`](@ref)." : ""
    for typ_str in typs
        @eval begin
            @doc """
                $($period_str)(dt::$($typ_str))

            The $($accessor_str) part of a $($typ_str) as a `$($period_str)`.$($reference)
            """ $period(dt::$(Symbol(typ_str))) = $period($(Symbol(accessor_str))(dt))
        end
    end
    @eval begin
        @doc """
            $($period_str)(v)

        Construct a `$($period_str)` object with the given `v` value. Input must be
        losslessly convertible to an [`Int64`](@ref).
        """ $period(v)
    end
end

#Print/show/traits
Base.print(io::IO, x::Period) = print(io, value(x), _units(x))
Base.show(io::IO, ::MIME"text/plain", x::Period) = print(io, x)
Base.show(io::IO, p::P) where {P<:Period} = print(io, P, '(', value(p), ')')
Base.zero(::Union{Type{P},P}) where {P<:Period} = P(0)
Base.one(::Union{Type{P},P}) where {P<:Period} = 1  # see #16116
Base.typemin(::Type{P}) where {P<:Period} = P(typemin(Int64))
Base.typemax(::Type{P}) where {P<:Period} = P(typemax(Int64))
Base.isfinite(::Union{Type{P}, P}) where {P<:Period} = true

# Default values (as used by TimeTypes)
"""
    default(p::Period)::Period

Return a sensible "default" value for the input Period by returning `T(1)` for Year,
Month, and Day, and `T(0)` for Hour, Minute, Second, and Millisecond.
"""
function default end

default(p::Union{T,Type{T}}) where {T<:DatePeriod} = T(1)
default(p::Union{T,Type{T}}) where {T<:TimePeriod} = T(0)

(-)(x::P) where {P<:Period} = P(-value(x))
==(x::P, y::P) where {P<:Period} = value(x) == value(y)
Base.isless(x::P, y::P) where {P<:Period} = isless(value(x), value(y))

# Period Arithmetic, grouped by dimensionality:
for op in (:+, :-, :lcm, :gcd)
    @eval ($op)(x::P, y::P) where {P<:Period} = P(($op)(value(x), value(y)))
end

/(x::P, y::P) where {P<:Period} = /(value(x), value(y))
/(x::P, y::Real) where {P<:Period} = P(/(value(x), y))
div(x::P, y::P, r::RoundingMode) where {P<:Period} = div(value(x), value(y), r)
div(x::P, y::Real, r::RoundingMode) where {P<:Period} = P(div(value(x), Int64(y), r))

for op in (:rem, :mod)
    @eval begin
        ($op)(x::P, y::P) where {P<:Period} = P(($op)(value(x), value(y)))
        ($op)(x::P, y::Real) where {P<:Period} = P(($op)(value(x), Int64(y)))
    end
end

(*)(x::P, y::Real) where {P<:Period} = P(value(x) * y)
(*)(y::Real, x::Period) = x * y

(*)(A::Period, B::AbstractArray) = Broadcast.broadcast_preserving_zero_d(*, A, B)
(*)(A::AbstractArray, B::Period) = Broadcast.broadcast_preserving_zero_d(*, A, B)

for op in (:(==), :isless, :/, :rem, :mod, :lcm, :gcd)
    @eval ($op)(x::Period, y::Period) = ($op)(promote(x, y)...)
end
div(x::Period, y::Period, r::RoundingMode) = div(promote(x, y)..., r)

# intfuncs
Base.gcdx(a::T, b::T) where {T<:Period} = ((g, x, y) = gcdx(value(a), value(b)); return T(g), x, y)
Base.abs(a::T) where {T<:Period} = T(abs(value(a)))
Base.sign(x::Period) = sign(value(x))
Base.signbit(x::Period) = signbit(value(x))

# return (next coarser period, conversion factor):
coarserperiod(::Type{P}) where {P<:Period} = (P, 1)
coarserperiod(::Type{Nanosecond})  = (Microsecond, 1000)
coarserperiod(::Type{Microsecond}) = (Millisecond, 1000)
coarserperiod(::Type{Millisecond}) = (Second, 1000)
coarserperiod(::Type{Second}) = (Minute, 60)
coarserperiod(::Type{Minute}) = (Hour, 60)
coarserperiod(::Type{Hour}) = (Day, 24)
coarserperiod(::Type{Day}) = (Week, 7)
coarserperiod(::Type{Month}) = (Year, 12)

# Stores multiple periods in greatest to least order by type, not values,
# canonicalized to eliminate zero periods, merge equal period types,
# and convert more-precise periods to less-precise periods when possible
"""
    CompoundPeriod

A `CompoundPeriod` is useful for expressing time periods that are not a fixed multiple of
smaller periods. For example, "a year and a day" is not a fixed number of days, but can
be expressed using a `CompoundPeriod`. In fact, a `CompoundPeriod` is automatically
generated by addition of different period types, e.g. `Year(1) + Day(1)` produces a
`CompoundPeriod` result.
"""
struct CompoundPeriod <: AbstractTime
    periods::Vector{Period}
    function CompoundPeriod(p::Vector{Period})
        n = length(p)
        if n > 1
            # We sort periods in decreasing order (rev = true) according to the length of
            # the period's type (by = tons ∘ oneunit). We sort by type, not value, so that
            # we can merge equal types.
            #
            # This works by computing how many nanoseconds are in a single period, and sorting
            # by that. For example, (tons ∘ oneunit)(Week(10)) = tons(oneunit(Week(10))) =
            # tons(Week(1)) ≈ 6.0e14, which is less than (tons ∘ oneunit)(Month(-2)) ≈ 2.6e15
            sort!(p, rev = true, by = tons ∘ oneunit)
            # canonicalize p by merging equal period types and removing zeros
            i = j = 1
            while j <= n
                k = j + 1
                while k <= n && typeof(p[j]) == typeof(p[k])
                    p[j] += p[k]
                    k += 1
                end
                if !iszero(p[j])
                    p[i] = p[j]
                    i += 1
                end
                j = k
            end
            n = i - 1 # new length
            p = resize!(p, n)
        elseif n == 1 && value(p[1]) == 0
            p = Period[]
        end

        return new(p)
    end
end

"""
    Dates.periods(::CompoundPeriod)::Vector{Period}

Return the `Vector` of `Period`s that comprise the given `CompoundPeriod`.

!!! compat "Julia 1.7"
    This function requires Julia 1.7 or later.
"""
periods(x::CompoundPeriod) = x.periods

"""
    CompoundPeriod(periods)

Construct a `CompoundPeriod` from a `Vector` of `Period`s. All `Period`s of the same type
will be added together.

# Examples
```jldoctest
julia> Dates.CompoundPeriod(Dates.Hour(12), Dates.Hour(13))
25 hours

julia> Dates.CompoundPeriod(Dates.Hour(-1), Dates.Minute(1))
-1 hour, 1 minute

julia> Dates.CompoundPeriod(Dates.Month(1), Dates.Week(-2))
1 month, -2 weeks

julia> Dates.CompoundPeriod(Dates.Minute(50000))
50000 minutes
```
"""
CompoundPeriod(p::Vector{<:Period}) = CompoundPeriod(Vector{Period}(p))

CompoundPeriod(t::Time) = CompoundPeriod(Period[Hour(t), Minute(t), Second(t), Millisecond(t),
                                                Microsecond(t), Nanosecond(t)])

CompoundPeriod(p::Period...) = CompoundPeriod(Period[p...])


"""
    canonicalize(::CompoundPeriod)::CompoundPeriod

Reduces the `CompoundPeriod` into its canonical form by applying the following rules:

* Any `Period` large enough be partially representable by a coarser `Period` will be broken
  into multiple `Period`s (eg. `Hour(30)` becomes `Day(1) + Hour(6)`)
* `Period`s with opposite signs will be combined when possible
  (eg. `Hour(1) - Day(1)` becomes `-Hour(23)`)

# Examples
```jldoctest
julia> canonicalize(Dates.CompoundPeriod(Dates.Hour(12), Dates.Hour(13)))
1 day, 1 hour

julia> canonicalize(Dates.CompoundPeriod(Dates.Hour(-1), Dates.Minute(1)))
-59 minutes

julia> canonicalize(Dates.CompoundPeriod(Dates.Month(1), Dates.Week(-2)))
1 month, -2 weeks

julia> canonicalize(Dates.CompoundPeriod(Dates.Minute(50000)))
4 weeks, 6 days, 17 hours, 20 minutes
```
"""
canonicalize(x::Period) = canonicalize(CompoundPeriod(x))
function canonicalize(x::CompoundPeriod)
    # canonicalize Periods by pushing "overflow" into a coarser period.
    p = x.periods
    n = length(p)
    if n > 0
        pc = sizehint!(Period[], n)
        P = typeof(p[n])
        v = value(p[n])
        i = n - 1
        while true
            Pc, f = coarserperiod(P)
            if i > 0 && typeof(p[i]) == P
                v += value(p[i])
                i -= 1
            end
            v0 = f == 1 ? v : rem(v, f)
            v0 != 0 && push!(pc, P(v0))
            if v != v0
                P = Pc
                v = div(v - v0, f)
            elseif i > 0
                P = typeof(p[i])
                v = value(p[i])
                i -= 1
            else
                break
            end
        end
        p = reverse!(pc)
        n = length(p)
    else
        return x
    end

    # reduce the amount of mixed positive/negative Periods.
    if n > 0
        pc = sizehint!(Period[], n)
        i = n
        while i > 0
            j = i

            # Determine sign of the largest period in this group which
            # can be converted into via coarserperiod.
            last = Union{}
            current = typeof(p[i])
            while i > 0 && current != last
                if typeof(p[i]) == current
                    i -= 1
                end
                last, current = current, coarserperiod(current)[1]
            end
            s = sign(value(p[i + 1]))

            # Adjust all the periods in the group based upon the
            # largest period sign.
            P = typeof(p[j])
            v = 0
            while j > i
                Pc, f = coarserperiod(P)
                if j > 0 && typeof(p[j]) == P
                    v += value(p[j])
                    j -= 1
                end
                v0 = f == 1 ? v : mod(v, f * s)
                v0 != 0 && push!(pc, P(v0))
                if v != v0
                    P = Pc
                    v = div(v - v0, f)
                elseif j > 0
                    P = typeof(p[j])
                    v = 0
                else
                    break
                end
            end
        end
        p = reverse!(pc)
    end

    return CompoundPeriod(p)
end

Base.convert(::Type{CompoundPeriod}, x::Period) = CompoundPeriod(Period[x])
function Base.string(x::CompoundPeriod)
    if isempty(x.periods)
        return "empty period"
    else
        s = ""
        for p in x.periods
            s *= ", " * string(p)
        end
        return s[3:end]
    end
end
Base.show(io::IO,x::CompoundPeriod) = print(io, string(x))

Base.convert(::Type{T}, x::CompoundPeriod) where T<:Period =
    isconcretetype(T) ? sum(T, x.periods; init = zero(T)) : throw(MethodError(convert,(T,x)))

# E.g. Year(1) + Day(1)
(+)(x::Period,y::Period) = CompoundPeriod(Period[x, y])
(+)(x::CompoundPeriod, y::Period) = CompoundPeriod(vcat(x.periods, y))
(+)(y::Period, x::CompoundPeriod) = x + y
(+)(x::CompoundPeriod, y::CompoundPeriod) = CompoundPeriod(vcat(x.periods, y.periods))
# E.g. Year(1) - Month(1)
(-)(x::Period, y::Period) = CompoundPeriod(Period[x, -y])
(-)(x::CompoundPeriod, y::Period) = CompoundPeriod(vcat(x.periods, -y))
(-)(x::CompoundPeriod) = CompoundPeriod(-x.periods)
(-)(y::Union{Period, CompoundPeriod}, x::CompoundPeriod) = (-x) + y

GeneralPeriod = Union{Period, CompoundPeriod}
(+)(x::GeneralPeriod) = x

(==)(x::CompoundPeriod, y::Period) = x == CompoundPeriod(y)
(==)(x::Period, y::CompoundPeriod) = y == x
(==)(x::CompoundPeriod, y::CompoundPeriod) = canonicalize(x).periods == canonicalize(y).periods

Base.isequal(x::CompoundPeriod, y::Period) = isequal(x, CompoundPeriod(y))
Base.isequal(x::Period, y::CompoundPeriod) = isequal(y, x)
Base.isequal(x::CompoundPeriod, y::CompoundPeriod) = isequal(x.periods, y.periods)

# Capture TimeType+-Period methods
(+)(a::TimeType, b::Period, c::Period) = (+)(a, b + c)
(+)(a::TimeType, b::Period, c::Period, d::Period...) = (+)((+)(a, b + c), d...)

function (+)(x::TimeType, y::CompoundPeriod)
    for p in y.periods
        x += p
    end
    return x
end
(+)(x::CompoundPeriod, y::TimeType) = y + x

function (-)(x::TimeType, y::CompoundPeriod)
    for p in y.periods
        x -= p
    end
    return x
end

# Fixed-value Periods (periods corresponding to a well-defined time interval,
# as opposed to variable calendar intervals like Year).
const FixedPeriod = Union{Week, Day, Hour, Minute, Second, Millisecond, Microsecond, Nanosecond}

# like div but throw an error if remainder is nonzero
function divexact(x, y)
    q, r = divrem(x, y)
    r == 0 || throw(InexactError(:divexact, Int, x/y))
    return q
end

# TODO: this is needed to prevent undefined Period constructors from
# hitting the deprecated construct-to-convert fallback.
(::Type{T})(p::Period) where {T<:Period} = convert(T, p)::T

# Conversions and promotion rules
function define_conversions(periods)
    for i = eachindex(periods)
        T, n = periods[i]
        N = Int64(1)
        for j = (i - 1):-1:firstindex(periods) # less-precise periods
            Tc, nc = periods[j]
            N *= nc
            vmax = typemax(Int64) ÷ N
            vmin = typemin(Int64) ÷ N
            @eval function Base.convert(::Type{$T}, x::$Tc)
                $vmin ≤ value(x) ≤ $vmax || throw(InexactError(:convert, $T, x))
                return $T(value(x) * $N)
            end
        end
        N = n
        for j = (i + 1):lastindex(periods) # more-precise periods
            Tc, nc = periods[j]
            @eval Base.convert(::Type{$T}, x::$Tc) = $T(divexact(value(x), $N))
            @eval Base.promote_rule(::Type{$T}, ::Type{$Tc}) = $Tc
            N *= nc
        end
    end
end
define_conversions([(:Week, 7), (:Day, 24), (:Hour, 60), (:Minute, 60), (:Second, 1000),
                    (:Millisecond, 1000), (:Microsecond, 1000), (:Nanosecond, 1)])
define_conversions([(:Year, 4), (:Quarter, 3), (:Month, 1)])

# fixed is not comparable to other periods, except when both are zero (#37459)
const OtherPeriod = Union{Month, Quarter, Year}
(==)(x::FixedPeriod, y::OtherPeriod) = iszero(x) & iszero(y)
(==)(x::OtherPeriod, y::FixedPeriod) = y == x

const zero_or_fixedperiod_seed = UInt === UInt64 ? 0x5b7fc751bba97516 : 0xeae0fdcb
const nonzero_otherperiod_seed = UInt === UInt64 ? 0xe1837356ff2d2ac9 : 0x170d1b00
otherperiod_seed(x) = iszero(value(x)) ? zero_or_fixedperiod_seed : nonzero_otherperiod_seed
# tons() will overflow for periods longer than ~300,000 years, implying a hash collision
# which is relatively harmless given how infrequently such periods should appear
Base.hash(x::FixedPeriod, h::UInt) = hash(tons(x), h + zero_or_fixedperiod_seed)
# Overflow can also happen here for really long periods (~8e17 years)
Base.hash(x::Year, h::UInt) = hash(12 * value(x), h + otherperiod_seed(x))
Base.hash(x::Quarter, h::UInt) = hash(3 * value(x), h + otherperiod_seed(x))
Base.hash(x::Month, h::UInt) = hash(value(x), h + otherperiod_seed(x))

function Base.hash(x::CompoundPeriod, h::UInt)
    isempty(x.periods) && return hash(0, h + zero_or_fixedperiod_seed)
    for p in x.periods
        h = hash(p, h)
    end
    return h
end

Base.isless(x::FixedPeriod, y::OtherPeriod) = throw(MethodError(isless, (x, y)))
Base.isless(x::OtherPeriod, y::FixedPeriod) = throw(MethodError(isless, (x, y)))

Base.isless(x::Period, y::CompoundPeriod) = CompoundPeriod(x) < y
Base.isless(x::CompoundPeriod, y::Period) = x < CompoundPeriod(y)
Base.isless(x::CompoundPeriod, y::CompoundPeriod) = tons(x) < tons(y)
# truncating conversions to milliseconds, nanoseconds and days:
# overflow can happen for periods longer than ~300,000 years
toms(c::Nanosecond)  = div(value(c), 1000000, RoundNearest)
toms(c::Microsecond) = div(value(c), 1000, RoundNearest)
toms(c::Millisecond) = value(c)
toms(c::Second)      = 1000 * value(c)
toms(c::Minute)      = 60000 * value(c)
toms(c::Hour)        = 3600000 * value(c)
toms(c::Period)      = 86400000 * days(c)
toms(c::CompoundPeriod) = isempty(c.periods) ? 0.0 : sum(p -> convert(Float64, toms(p))::Float64, c.periods)
tons(x)              = toms(x) * 1000000
tons(x::Microsecond) = value(x) * 1000
tons(x::Nanosecond)  = value(x)
tons(c::CompoundPeriod) = isempty(c.periods) ? 0.0 : sum(p -> convert(Float64, tons(p))::Float64, c.periods)
days(c::Millisecond) = div(value(c), 86400000)
days(c::Second)      = div(value(c), 86400)
days(c::Minute)      = div(value(c), 1440)
days(c::Hour)        = div(value(c), 24)
days(c::Day)         = value(c)
days(c::Week)        = 7 * value(c)
days(c::Year)        = 365.2425 * value(c)
days(c::Quarter)     = 91.310625 * value(c)
days(c::Month)       = 30.436875 * value(c)
days(c::CompoundPeriod) = isempty(c.periods) ? 0.0 : sum(p -> convert(Float64, days(p))::Float64, c.periods)
seconds(x::Nanosecond) = value(x) / 1000000000
seconds(x::Microsecond) = value(x) / 1000000
seconds(x::Millisecond) = value(x) / 1000
seconds(x::Period) = value(Second(x))
