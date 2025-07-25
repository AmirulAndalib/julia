# This file is a part of Julia. License is MIT: https://julialang.org/license

using Random, LinearAlgebra
isdefined(Main, :OffsetArrays) || @eval Main include("testhelpers/OffsetArrays.jl")
using .Main.OffsetArrays

types = Any[
    Bool,
    Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float32, Float64,
    Rational{Int8}, Rational{UInt8}, Rational{Int16}, Rational{UInt16},
    Rational{Int32}, Rational{UInt32}, Rational{Int64}, Rational{UInt64},
    BigFloat, BigInt, Rational{BigInt}
]
vals = vcat(
    typemin(Int64),
    -Int64(maxintfloat(Float64)) .+ Int64[-4:1;],
    typemin(Int32),
    -Integer(maxintfloat(Float32)) .+ (-4:1),
    -2:2,
    Integer(maxintfloat(Float32)) .+ (-1:4),
    typemax(Int32),
    Int64(maxintfloat(Float64)) .+ Int64[-1:4;],
    typemax(Int64),
)

function coerce(T::Type, x)
    if T<:Rational
        convert(T, coerce(typeof(numerator(zero(T))), x))
    elseif !(T<:Integer)
        convert(T, x)
    else
        x % T
    end
end

for T = types[2:end], x = vals
    a = coerce(T, x)
    @test hash(a, zero(UInt)) == invoke(hash, Tuple{Real, UInt}, a, zero(UInt))
    @test hash(a, one(UInt)) == invoke(hash, Tuple{Real, UInt}, a, one(UInt))
end

let collides = 0
    for T = types, S = types, x = vals
        a = coerce(T, x)
        b = coerce(S, x)
        eq = hash(a) == hash(b)
        #println("$(typeof(a)) $a")
        #println("$(typeof(b)) $b")
        if isequal(a, b)
            @test eq
        else
            collides += eq
        end
    end
    @test collides <= 516
end
@test hash(0.0) != hash(-0.0)

# issue #8619
@test hash(nextfloat(2.0^63)) == hash(UInt64(nextfloat(2.0^63)))
@test hash(prevfloat(2.0^64)) == hash(UInt64(prevfloat(2.0^64)))

# issue #48744
@test hash(typemin(Int)//1) === hash(big(typemin(Int)//1))

# issue #9264
@test hash(1//6,zero(UInt)) == invoke(hash, Tuple{Real, UInt}, 1//6, zero(UInt))
@test hash(1//6) == hash(big(1)//big(6))
@test hash(1//6) == hash(0x01//0x06)

# hashing collections (e.g. issue #6870)
vals = Any[
    [1,2,3,4], [1 3;2 4], Any[1,2,3,4], [1,3,2,4],
    [1.0, 2.0, 3.0, 4.0], BigInt[1, 2, 3, 4],
    [1,0], [true,false], BitArray([true,false]),
    # Irrationals
    Any[1, pi], [1, pi], [pi, pi], Any[pi, pi],
    # Overflow with Int8
    Any[Int8(127), Int8(-128), -383], 127:-255:-383,
    # Loss of precision with Float64
    Any[-Int64(2)^53-1, 0.0, Int64(2)^53+1], [-Int64(2)^53-1, 0, Int64(2)^53+1],
        (-Int64(2)^53-1):Int64(2)^53+1:(Int64(2)^53+1),
    # Some combinations of elements support -, others do not
    [1, 2, "a"], [1, "a", 2], [1, 2, "a", 2], [1, 'a', 2],
    Set([1,2,3,4]),
    Set([1:10;]),                # these lead to different key orders
    Set([7,9,4,10,2,3,5,8,6,1]), #
    Dict(42 => 101, 77 => 93), Dict{Any,Any}(42 => 101, 77 => 93),
    (1,2,3,4), (1.0,2.0,3.0,4.0), (1,3,2,4),
    ("a","b"), (SubString("a",1,1), SubString("b",1,1)),
    join('c':'s'), SubString(join('a':'z'), 3, 19),
    # issue #6900
    Dict(x => x for x in 1:10),
    Dict(7=>7,9=>9,4=>4,10=>10,2=>2,3=>3,8=>8,5=>5,6=>6,1=>1),
    [], [1], [2], [1, 1], [1, 2], [1, 3], [2, 2], [1, 2, 2], [1, 3, 3],
    zeros(2, 2), Matrix(1.0I, 2, 2), fill(1., 2, 2),
    [-0. 0; -0. 0.],
    # issue #16364
    1:4, 1:1:4, 1:-1:0, 1.0:4.0, 1.0:1.0:4.0, range(1, stop=4, length=4),
    # issue #35597, when `LinearIndices` does not begin at 1
    Base.IdentityUnitRange(2:4),
    OffsetArray(1:4, -2),
    OffsetArray([1 3; 2 4], -2, 2),
    OffsetArray(1:4, 0),
    OffsetArray([1 3; 2 4], 0, 0),
    'a':'e', ['a', 'b', 'c', 'd', 'e'],
    # check that hash is still consistent with heterogeneous arrays for which - is defined
    # for some pairs and not others
    ["a", "b", 1, 2], ["a", 1, 2], ["a", "b", 2, 2], ["a", "a", 1, 2], ["a", "b", 2, 3]
]

for (i, a) in enumerate(vals), b in vals[i:end]
    @test isequal(a,b) == (hash(a)==hash(b))
end

for a in vals
    a isa AbstractArray || continue
    aa  = copyto!(Array{eltype(a)}(undef, size(a)), a)
    aaa = copyto!(Array{Any}(undef, size(a)), a)
    if keys(a) == keys(aa)
        @test hash(a) == hash(aa) == hash(aaa)
    else
        @test hash(a) == hash(OffsetArray(aa, (first.(axes(a)).-1)...)) == hash(OffsetArray(aaa, (first.(axes(a)).-1)...))
    end
end

vals = Any[
    Int[], Float64[],
    [0], [1], [2],
    # test vectors starting with ranges
    [1, 2], [1, 2, 3], [1, 2, 3, 4], [1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 6],
    [2, 1], [3, 2, 1], [4, 3, 2, 1], [5, 4, 3, 2, 1], [5, 4, 3, 2, 1, 0, -1],
    # test vectors starting with ranges which trigger overflow with Int8
    [124, 125, 126, 127], [124, 125, 126, 127, -128], [-128, 127, -128],
    # test vectors including ranges
    [2, 1, 2, 3], [2, 3, 2, 1], [2, 1, 2, 3, 2], [2, 3, 2, 1, 2],
    # test various sparsity patterns
    [0, 0], [0, 0, 0], [0, 1], [1, 0],
    [0, 0, 1], [0, 1, 0], [1, 0, 0], [0, 1, 2],
    [0 0; 0 0], [1 0; 0 0], [0 1; 0 0], [0 0; 1 0], [0 0; 0 1],
    [5 1; 0 0], [1 1; 0 1], [0 2; 3 0], [0 2; 4 6], [4 0; 0 1],
    [0 0 0; 0 0 0], [1 0 0; 0 0 1], [0 0 2; 3 0 0], [0 0 7; 6 1 2],
    [4 0 0; 3 0 1], [0 2 4; 6 0 0],
]

for a in vals
    b = Array(a)
    @test hash(convert(Array{Any}, a)) == hash(b)
    @test hash(convert(Array{supertype(eltype(a))}, a)) == hash(b)
    @test hash(convert(Array{Float64}, a)) == hash(b)
    if !any(x -> isequal(x, -0.0), a)
        @test hash(convert(Array{Int}, a)) == hash(b)
        if all(x -> typemin(Int8) <= x <= typemax(Int8), a)
            @test hash(convert(Array{Int8}, a)) == hash(b)
        end
    end
end

# Test that overflow does not give inconsistent hashes with heterogeneous arrays
@test hash(Any[Int8(1), Int8(2), 255]) == hash([1, 2, 255])
@test hash(Any[Int8(127), Int8(-128), 129, 130]) ==
    hash([127, -128, 129, 130]) != hash([127,  128, 129, 130])

vals = Any[
    0.0:0.1:0.3, 0.3:-0.1:0.0,
    0:-1:1, 0.0:-1.0:1.0, 0.0:1.1:10.0, -4:10,
    'a':'e', 'b':'a',
    range(1, stop=1, length=1), range(0.3, stop=1.0, length=3),  range(1, stop=1.1, length=20)
]

for a in vals
    @test hash(Array(a)) == hash(a)
end

@test hash(SubString("--hello--",3,7)) == hash("hello")
@test hash(:(X.x)) == hash(:(X.x))
@test hash(:(X.x)) != hash(:(X.y))

@test hash([1,2]) == hash(view([1,2,3,4],1:2))

let a = QuoteNode(1), b = QuoteNode(1.0)
    @test hash(a) == hash(b)
    @test a != b
end
let a = QuoteNode(:(1 + 2)), b = QuoteNode(:(1 + 2))
    @test hash(a) == hash(b)
    @test a == b
end


let a = Expr(:block, Core.SlotNumber(1)),
    b = Expr(:block, Core.SlotNumber(1)),
    c = Expr(:block, Core.SlotNumber(3))
    @test a == b && hash(a) == hash(b)
    @test a != c && hash(a) != hash(c)
    @test b != c && hash(b) != hash(c)
end

@test hash(Dict(),hash(Set())) != hash(Set(),hash(Dict()))

# issue 15659
for prec in [3, 11, 15, 16, 31, 32, 33, 63, 64, 65, 254, 255, 256, 257, 258, 1023, 1024, 1025],
    v in Any[-0.0, 0, 1, -1, 1//10, 2//10, 3//10, 1//2, pi]
    setprecision(prec) do
        x = convert(BigFloat, v)
        @test precision(x) == prec
        num, pow, den = Base.decompose(x)
        y = num*big(2.0)^pow/den
        @test precision(y) == prec
        @test isequal(x, y)
    end
end

# issue #20744
@test hash(:c, hash(:b, hash(:a))) != hash(:a, hash(:b, hash(:c)))

# issue #5849, objectid of types
@test Vector === (Array{T,1} where T)
@test (Pair{A,B} where A where B) !== (Pair{A,B} where B where A)
let vals_expr = :(Any[Vector, (Array{T,1} where T), 1, 2, Union{Int, String}, Union{String, Int},
                      (Union{String, T} where T), Ref{Ref{T} where T}, (Ref{Ref{T}} where T),
                      (Vector{T} where T<:Real), (Vector{T} where T<:Integer),
                      (Vector{T} where T>:Integer),
                      (Pair{A,B} where A where B), (Pair{A,B} where B where A)])
    vals_a = eval(vals_expr)
    vals_b = eval(vals_expr)
    for (i, a) in enumerate(vals_a), (j, b) in enumerate(vals_b)
        @test i != j || (a === b)
        @test (a === b) == (objectid(a) == objectid(b))
    end
end

# issue #26038
let p1 = Ptr{Int8}(1), p2 = Ptr{Int32}(1), p3 = Ptr{Int8}(2)
    @test p1 == p2
    @test !isequal(p1, p2)
    @test p1 != p3
    @test hash(p1) != hash(p2)
    @test hash(p1) != hash(p3)
    @test hash(p1) == hash(Ptr{Int8}(1))

    @test p1 < p3
    @test !(p1 < p2)
    @test isless(p1, p3)
    @test_throws MethodError isless(p1, p2)
end

# PR #40083
@test hash(1:1000) == hash(collect(1:1000))

@testset "test the other core data hashing functions" begin
    @testset "hash_64_32" begin
        vals = vcat(
            typemin(UInt64) .+ UInt64[1:4;],
            typemax(UInt64) .- UInt64[4:-1:0;]
        )

        for a in vals, b in vals
            ha = Base.hash_64_32(a)
            hb = Base.hash_64_32(b)
            @test isequal(a, b) == (ha == hb)
        end
    end

    @testset "hash_32_32" begin
        vals = vcat(
            typemin(UInt32) .+ UInt32[1:4;],
            typemax(UInt32) .- UInt32[4:-1:0;]
        )

        for a in vals, b in vals
            ha = Base.hash_32_32(a)
            hb = Base.hash_32_32(b)
            @test isequal(a, b) == (ha == hb)
        end
    end
end

if Sys.WORD_SIZE >= 64
    @testset "very large string" begin
        N = 2^31+1
        s = String('\0'^N);
        objectid(s)
    end
end

# Issue #49620
let t1 = Tuple{AbstractVector,AbstractVector{<:Integer},UnitRange{<:Integer}},
    t2 = Tuple{AbstractVector,AbstractVector{<:Integer},UnitRange{<:Integer}}
    @test hash(t1) == hash(t2)
    @test length(Set{Type}([t1, t2])) == 1
end

struct AUnionParam{T<:Union{Nothing,Float32,Float64}} end
@test AUnionParam.body.hash == 0
@test Type{AUnionParam}.hash != 0
@test Type{AUnionParam{<:Union{Float32,Float64}}}.hash == 0
@test Type{AUnionParam{<:Union{Nothing,Float32,Float64}}} === Type{AUnionParam}
@test Type{AUnionParam.body}.hash == 0
@test Type{Base.Broadcast.Broadcasted}.hash != 0


@testset "issue 50628" begin
    # test hashing of rationals that equal floats are equal to the float hash
    @test hash(5//2) == hash(big(5)//2) == hash(2.5)
    # test hashing of rational that are integers hash to the integer
    @test hash(Int64(5)^25) == hash(big(5)^25) == hash(Int64(5)^25//1) == hash(big(5)^25//1)
    # test integer/rational that don't fit in Float64 don't hash as Float64
    @test hash(Int64(5)^25) != hash(5.0^25)
    @test hash((Int64(5)//2)^25) == hash(big(5//2)^25)
    # test integer/rational that don't fit in Float64 don't hash as Float64
    @test hash((Int64(5)//2)^25) != hash(2.5^25)
    # test hashing of rational with odd denominator
    @test hash(5//3) == hash(big(5)//3)
end

@testset "concrete eval type hash" begin
    @test Core.Compiler.is_foldable_nothrow(Base.infer_effects(hash, Tuple{Type{Int}, UInt}))

    f(h...) = hash(Char, h...);
    src = only(code_typed(f, Tuple{UInt}))[1]
    @test count(stmt -> Meta.isexpr(stmt, :foreigncall), src.code) == 0
end
