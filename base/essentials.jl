# This file is a part of Julia. License is MIT: https://julialang.org/license

using Core: CodeInfo, SimpleVector, donotdelete, compilerbarrier, memoryref, memoryrefnew, memoryrefget, memoryrefset!

const Callable = Union{Function,Type}

const Bottom = Union{}

# Define minimal array interface here to help code used in macros:
length(a::Array{T, 0}) where {T} = 1
length(a::Array{T, 1}) where {T} = getfield(a, :size)[1]
length(a::Array{T, 2}) where {T} = (sz = getfield(a, :size); sz[1] * sz[2])
# other sizes are handled by generic prod definition for AbstractArray
length(a::GenericMemory) = getfield(a, :length)
throw_boundserror(A, I) = (@noinline; throw(BoundsError(A, I)))

# multidimensional getindex will be defined later on

==(a::GlobalRef, b::GlobalRef) = a.mod === b.mod && a.name === b.name

"""
    AbstractSet{T}

Supertype for set-like types whose elements are of type `T`.
[`Set`](@ref), [`BitSet`](@ref) and other types are subtypes of this.
"""
abstract type AbstractSet{T} end

"""
    AbstractDict{K, V}

Supertype for dictionary-like types with keys of type `K` and values of type `V`.
[`Dict`](@ref), [`IdDict`](@ref) and other types are subtypes of this.
An `AbstractDict{K, V}` should be an iterator of `Pair{K, V}`.
"""
abstract type AbstractDict{K,V} end

## optional pretty printer:
#const NamedTuplePair{N, V, names, T<:NTuple{N, Any}} = Pairs{Symbol, V, NTuple{N, Symbol}, NamedTuple{names, T}}
#export NamedTuplePair

macro _gc_preserve_begin(arg1)
    Expr(:gc_preserve_begin, esc(arg1))
end

macro _gc_preserve_end(token)
    Expr(:gc_preserve_end, esc(token))
end

"""
    @nospecialize

Applied to a function argument name, hints to the compiler that the method
implementation should not be specialized for different types of that argument,
but instead use the declared type for that argument.
It can be applied to an argument within a formal argument list,
or in the function body.
When applied to an argument, the macro must wrap the entire argument expression, e.g.,
`@nospecialize(x::Real)` or `@nospecialize(i::Integer...)` rather than wrapping just the argument name.
When used in a function body, the macro must occur in statement position and
before any code.

When used without arguments, it applies to all arguments of the parent scope.
In local scope, this means all arguments of the containing function.
In global (top-level) scope, this means all methods subsequently defined in the current module.

Specialization can reset back to the default by using [`@specialize`](@ref).

```julia
function example_function(@nospecialize x)
    ...
end

function example_function(x, @nospecialize(y = 1))
    ...
end

function example_function(x, y, z)
    @nospecialize x y
    ...
end

@nospecialize
f(y) = [x for x in y]
@specialize
```

!!! note
    `@nospecialize` affects code generation but not inference: it limits the diversity
    of the resulting native code, but it does not impose any limitations (beyond the
    standard ones) on type-inference. Use [`Base.@nospecializeinfer`](@ref) together with
    `@nospecialize` to additionally suppress inference.

# Examples

```jldoctest; setup = :(using InteractiveUtils)
julia> f(A::AbstractArray) = g(A)
f (generic function with 1 method)

julia> @noinline g(@nospecialize(A::AbstractArray)) = A[1]
g (generic function with 1 method)

julia> @code_typed f([1.0])
CodeInfo(
1 ─ %1 =    invoke g(A::AbstractArray)::Float64
└──      return %1
) => Float64
```

Here, the `@nospecialize` annotation results in the equivalent of

```julia
f(A::AbstractArray) = invoke(g, Tuple{AbstractArray}, A)
```

ensuring that only one version of native code will be generated for `g`,
one that is generic for any `AbstractArray`.
However, the specific return type is still inferred for both `g` and `f`,
and this is still used in optimizing the callers of `f` and `g`.
"""
macro nospecialize(vars...)
    if nfields(vars) === 1
        # in argument position, need to fix `@nospecialize x=v` to `@nospecialize (kw x v)`
        var = getfield(vars, 1)
        if isa(var, Expr) && var.head === :(=)
            var.head = :kw
        end
    end
    return Expr(:meta, :nospecialize, vars...)
end

"""
    @specialize

Reset the specialization hint for an argument back to the default.
For details, see [`@nospecialize`](@ref).
"""
macro specialize(vars...)
    if nfields(vars) === 1
        # in argument position, need to fix `@specialize x=v` to `@specialize (kw x v)`
        var = getfield(vars, 1)
        if isa(var, Expr) && var.head === :(=)
            var.head = :kw
        end
    end
    return Expr(:meta, :specialize, vars...)
end

"""
    @isdefined(s)::Bool

Tests whether variable `s` is defined in the current scope.

See also [`isdefined`](@ref) for field properties and [`isassigned`](@ref) for
array indexes or [`haskey`](@ref) for other mappings.

# Examples
```jldoctest
julia> @isdefined newvar
false

julia> newvar = 1
1

julia> @isdefined newvar
true

julia> function f()
           println(@isdefined x)
           x = 3
           println(@isdefined x)
       end
f (generic function with 1 method)

julia> f()
false
true
```
"""
macro isdefined(s::Symbol)
    return Expr(:escape, Expr(:isdefined, s))
end

_nameof(m::Module) = ccall(:jl_module_name, Ref{Symbol}, (Any,), m)

function _is_internal(__module__)
    return _nameof(__module__) === :Base ||
      _nameof(ccall(:jl_base_relative_to, Any, (Any,), __module__)::Module) === :Compiler
end

# can be used in place of `@assume_effects :total` (supposed to be used for bootstrapping)
macro _total_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#true,
        #=:effect_free=#true,
        #=:nothrow=#true,
        #=:terminates_globally=#true,
        #=:terminates_locally=#false,
        #=:notaskstate=#true,
        #=:inaccessiblememonly=#true,
        #=:noub=#true,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#true))
end
# can be used in place of `@assume_effects :foldable` (supposed to be used for bootstrapping)
macro _foldable_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#true,
        #=:effect_free=#true,
        #=:nothrow=#false,
        #=:terminates_globally=#true,
        #=:terminates_locally=#false,
        #=:notaskstate=#true,
        #=:inaccessiblememonly=#true,
        #=:noub=#true,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#true))
end
# can be used in place of `@assume_effects :terminates_locally` (supposed to be used for bootstrapping)
macro _terminates_locally_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#false,
        #=:terminates_locally=#true,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :terminates_globally` (supposed to be used for bootstrapping)
macro _terminates_globally_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#true,
        #=:terminates_locally=#true,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :terminates_globally :notaskstate` (supposed to be used for bootstrapping)
macro _terminates_globally_notaskstate_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#true,
        #=:terminates_locally=#true,
        #=:notaskstate=#true,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :terminates_globally :noub` (supposed to be used for bootstrapping)
macro _terminates_globally_noub_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#true,
        #=:terminates_locally=#true,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#true,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :effect_free :terminates_locally` (supposed to be used for bootstrapping)
macro _effect_free_terminates_locally_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#true,
        #=:nothrow=#false,
        #=:terminates_globally=#false,
        #=:terminates_locally=#true,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :nothrow :noub` (supposed to be used for bootstrapping)
macro _nothrow_noub_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#true,
        #=:terminates_globally=#false,
        #=:terminates_locally=#false,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#true,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :nothrow` (supposed to be used for bootstrapping)
macro _nothrow_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#true,
        #=:terminates_globally=#false,
        #=:terminates_locally=#false,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :noub` (supposed to be used for bootstrapping)
macro _noub_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#false,
        #=:terminates_locally=#false,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#true,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :notaskstate` (supposed to be used for bootstrapping)
macro _notaskstate_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#false,
        #=:terminates_locally=#false,
        #=:notaskstate=#true,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#false,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end
# can be used in place of `@assume_effects :noub_if_noinbounds` (supposed to be used for bootstrapping)
macro _noub_if_noinbounds_meta()
    return _is_internal(__module__) && Expr(:meta, Expr(:purity,
        #=:consistent=#false,
        #=:effect_free=#false,
        #=:nothrow=#false,
        #=:terminates_globally=#false,
        #=:terminates_locally=#false,
        #=:notaskstate=#false,
        #=:inaccessiblememonly=#false,
        #=:noub=#false,
        #=:noub_if_noinbounds=#true,
        #=:consistent_overlay=#false,
        #=:nortcall=#false))
end

# another version of inlining that propagates an inbounds context
macro _propagate_inbounds_meta()
    return Expr(:meta, :inline, :propagate_inbounds)
end
macro _nospecializeinfer_meta()
    return Expr(:meta, :nospecializeinfer)
end

# These special checkbounds methods are defined early for bootstrapping
function checkbounds(::Type{Bool}, A::Union{Array, Memory}, i::Int)
    @inline
    ult_int(bitcast(UInt, sub_int(i, 1)), bitcast(UInt, length(A)))
end
function checkbounds(A::Union{Array, GenericMemory}, i::Int)
    @inline
    checkbounds(Bool, A, i) || throw_boundserror(A, (i,))
end

default_access_order(a::GenericMemory{:not_atomic}) = :not_atomic
default_access_order(a::GenericMemory{:atomic}) = :monotonic
default_access_order(a::GenericMemoryRef{:not_atomic}) = :not_atomic
default_access_order(a::GenericMemoryRef{:atomic}) = :monotonic

function getindex(A::GenericMemory, i::Int)
    @_noub_if_noinbounds_meta
    (@_boundscheck) && checkbounds(A, i)
    memoryrefget(memoryrefnew(A, i, false), default_access_order(A), false)
end

getindex(A::GenericMemoryRef) = memoryrefget(A, default_access_order(A), @_boundscheck)

"""
    nameof(m::Module)::Symbol

Get the name of a `Module` as a [`Symbol`](@ref).

# Examples
```jldoctest
julia> nameof(Base.Broadcast)
:Broadcast
```
"""
nameof(m::Module) = (@_total_meta; ccall(:jl_module_name, Ref{Symbol}, (Any,), m))

typeof(function iterate end).name.constprop_heuristic = Core.ITERATE_HEURISTIC

"""
    convert(T, x)

Convert `x` to a value of type `T`.

If `T` is an [`Integer`](@ref) type, an [`InexactError`](@ref) will be raised if `x`
is not representable by `T`, for example if `x` is not integer-valued, or is outside the
range supported by `T`.

# Examples
```jldoctest
julia> convert(Int, 3.0)
3

julia> convert(Int, 3.5)
ERROR: InexactError: Int64(3.5)
Stacktrace:
[...]
```

If `T` is an [`AbstractFloat`](@ref) type, then it will return the
closest value to `x` representable by `T`. Inf is treated as one
ulp greater than `floatmax(T)` for purposes of determining nearest.

```jldoctest
julia> x = 1/3
0.3333333333333333

julia> convert(Float32, x)
0.33333334f0

julia> convert(BigFloat, x)
0.333333333333333314829616256247390992939472198486328125
```

If `T` is a collection type and `x` a collection, the result of
`convert(T, x)` may share memory with all or part of `x`.
```jldoctest
julia> x = Int[1, 2, 3];

julia> y = convert(Vector{Int}, x);

julia> y === x
true
```

See also: [`round`](@ref), [`trunc`](@ref), [`oftype`](@ref), [`reinterpret`](@ref).
"""
function convert end

# ensure this is never ambiguous, and therefore fast for lookup
convert(T::Type{Union{}}, x...) = throw(ArgumentError("cannot convert a value to Union{} for assignment"))

convert(::Type{Type}, x::Type) = x # the ssair optimizer is strongly dependent on this method existing to avoid over-specialization
                                   # in the absence of inlining-enabled
                                   # (due to fields typed as `Type`, which is generally a bad idea)
# These end up being called during bootstrap and then would be invalidated if not for the following:
convert(::Type{String}, x::String) = x

"""
    @eval [mod,] ex

Evaluate an expression with values interpolated into it using `eval`.
If two arguments are provided, the first is the module to evaluate in.
"""
macro eval(ex)
    return Expr(:let, Expr(:(=), :eval_local_result,
            Expr(:escape, Expr(:call, GlobalRef(Core, :eval), __module__, Expr(:quote, ex)))),
        Expr(:block,
            Expr(:var"latestworld-if-toplevel"),
            :eval_local_result))
end
macro eval(mod, ex)
    return Expr(:let, Expr(:(=), :eval_local_result,
            Expr(:escape, Expr(:call, GlobalRef(Core, :eval), mod, Expr(:quote, ex)))),
        Expr(:block,
            Expr(:var"latestworld-if-toplevel"),
            :eval_local_result))
end

# use `@eval` here to directly form `:new` expressions avoid implicit `convert`s
# in order to achieve better effects inference
@eval struct Pairs{K, V, I, A} <: AbstractDict{K, V}
    data::A
    itr::I
    Pairs{K, V, I, A}(data, itr) where {K, V, I, A} = $(Expr(:new, :(Pairs{K, V, I, A}), :(data isa A ? data : convert(A, data)), :(itr isa I ? itr : convert(I, itr))))
    Pairs{K, V}(data::A, itr::I) where {K, V, I, A} = $(Expr(:new, :(Pairs{K, V, I, A}), :data, :itr))
    Pairs{K}(data::A, itr::I) where {K, I, A} = $(Expr(:new, :(Pairs{K, eltype(A), I, A}), :data, :itr))
    Pairs(data::A, itr::I) where  {I, A} = $(Expr(:new, :(Pairs{eltype(I), eltype(A), I, A}), :data, :itr))
end
pairs(::Type{NamedTuple}) = Pairs{Symbol, V, NTuple{N, Symbol}, NamedTuple{names, T}} where {V, N, names, T<:NTuple{N, Any}}

"""
    Base.Pairs(values, keys) <: AbstractDict{eltype(keys), eltype(values)}

Transforms an indexable container into a Dictionary-view of the same data.
Modifying the key-space of the underlying data may invalidate this object.
"""
Pairs

argtail(x, rest...) = rest

"""
    tail(x::Tuple)::Tuple

Return a `Tuple` consisting of all but the first component of `x`.

See also: [`front`](@ref Base.front), [`rest`](@ref Base.rest), [`first`](@ref), [`Iterators.peel`](@ref).

# Examples
```jldoctest
julia> Base.tail((1,2,3))
(2, 3)

julia> Base.tail(())
ERROR: ArgumentError: Cannot call tail on an empty tuple.
```
"""
tail(x::Tuple) = argtail(x...)
tail(::Tuple{}) = throw(ArgumentError("Cannot call tail on an empty tuple."))

function unwrap_unionall(@nospecialize(a))
    @_foldable_meta
    while isa(a,UnionAll)
        a = a.body
    end
    return a
end

function rewrap_unionall(@nospecialize(t), @nospecialize(u))
    @_foldable_meta
    if !isa(u, UnionAll)
        return t
    end
    return UnionAll(u.var, rewrap_unionall(t, u.body))
end

function rewrap_unionall(t::Core.TypeofVararg, @nospecialize(u))
    @_foldable_meta
    isdefined(t, :T) || return t
    if !isa(u, UnionAll)
        return t
    end
    T = rewrap_unionall(t.T, u)
    if !isdefined(t, :N) || t.N === u.var
        return Vararg{T}
    end
    return Vararg{T, t.N}
end

# replace TypeVars in all enclosing UnionAlls with fresh TypeVars
function rename_unionall(@nospecialize(u))
    if !isa(u, UnionAll)
        return u
    end
    var = u.var::TypeVar
    body = UnionAll(var, rename_unionall(u.body))
    nv = TypeVar(var.name, var.lb, var.ub)
    return UnionAll(nv, body{nv})
end

# remove concrete constraint on diagonal TypeVar if it comes from troot
function widen_diagonal(@nospecialize(t), troot::UnionAll)
    body = ccall(:jl_widen_diagonal, Any, (Any, Any), t, troot)
end

function isvarargtype(@nospecialize(t))
    return isa(t, Core.TypeofVararg)
end

function isvatuple(@nospecialize(t))
    @_foldable_meta
    t = unwrap_unionall(t)
    if isa(t, DataType)
        n = length(t.parameters)
        return n > 0 && isvarargtype(t.parameters[n])
    end
    return false
end

function unwrapva(@nospecialize(t))
    isa(t, Core.TypeofVararg) || return t
    return isdefined(t, :T) ? t.T : Any
end

function unconstrain_vararg_length(va::Core.TypeofVararg)
    # construct a new Vararg type where its length is unconstrained,
    # but its element type still captures any dependencies the input
    # element type may have had on the input length
    return Vararg{unwrapva(va)}
end

# Compute the minimum number of initialized fields for a particular datatype
# (therefore also a lower bound on the number of fields)
function datatype_min_ninitialized(@nospecialize t0)
    t = unwrap_unionall(t0)
    t isa DataType || return 0
    isabstracttype(t) && return 0
    if t.name === _NAMEDTUPLE_NAME
        names, types = t.parameters[1], t.parameters[2]
        if names isa Tuple
            return length(names)
        end
        t = argument_datatype(types)
        t isa DataType || return 0
        t.name === Tuple.name || return 0
    end
    if t.name === Tuple.name
        n = length(t.parameters)
        n == 0 && return 0
        va = t.parameters[n]
        if isvarargtype(va)
            n -= 1
            if isdefined(va, :N)
                va = va.N
                if va isa Int
                    n += va
                end
            end
        end
        return n
    end
    return length(t.name.names) - t.name.n_uninitialized
end

import Core: typename

_tuple_error(T::Type, x) = (@noinline; throw(MethodError(convert, (T, x))))

convert(::Type{T}, x::T) where {T<:Tuple} = x
function convert(::Type{T}, x::NTuple{N,Any}) where {N, T<:Tuple}
    # First see if there could be any conversion of the input type that'd be a subtype of the output.
    # If not, we'll throw an explicit MethodError (otherwise, it might throw a typeassert).
    if typeintersect(NTuple{N,Any}, T) === Union{}
        _tuple_error(T, x)
    end
    function cvt1(n)
        @inline
        Tn = fieldtype(T, n)
        xn = getfield(x, n, #=boundscheck=#false)
        xn isa Tn && return xn
        return convert(Tn, xn)
    end
    return ntuple(cvt1, Val(N))::NTuple{N,Any}
end

# optimizations?
# converting to tuple types of fixed length
#convert(::Type{T}, x::T) where {N, T<:NTuple{N,Any}} = x
#convert(::Type{T}, x::NTuple{N,Any}) where {N, T<:NTuple{N,Any}} =
#    ntuple(n -> convert(fieldtype(T, n), x[n]), Val(N))
#convert(::Type{T}, x::Tuple{Vararg{Any}}) where {N, T<:NTuple{N,Any}} =
#    throw(MethodError(convert, (T, x)))
# converting to tuple types of indefinite length
#convert(::Type{Tuple{Vararg{V}}}, x::Tuple{Vararg{V}}) where {V} = x
#convert(::Type{NTuple{N, V}}, x::NTuple{N, V}) where {N, V} = x
#function convert(T::Type{Tuple{Vararg{V}}}, x::Tuple) where {V}
#    @isdefined(V) || (V = fieldtype(T, 1))
#    return map(t -> convert(V, t), x)
#end
#function convert(T::Type{NTuple{N, V}}, x::NTuple{N, Any}) where {N, V}
#    @isdefined(V) || (V = fieldtype(T, 1))
#    return map(t -> convert(V, t), x)
#end
# short tuples
#convert(::Type{Tuple{}}, ::Tuple{}) = ()
#convert(::Type{Tuple{S}}, x::Tuple{S}) where {S} = x
#convert(::Type{Tuple{S, T}}, x::Tuple{S, T}) where {S, T} = x
#convert(::Type{Tuple{S, T, U}}, x::Tuple{S, T, U}) where {S, T, U} = x
#convert(::Type{Tuple{S}}, x::Tuple{Any}) where {S} = (convert(S, x[1]),)
#convert(::Type{Tuple{S, T}}, x::Tuple{Any, Any}) where {S, T} = (convert(S, x[1]), convert(T, x[2]),)
#convert(::Type{Tuple{S, T, U}}, x::Tuple{Any, Any, Any}) where {S, T, U} = (convert(S, x[1]), convert(T, x[2]), convert(U, x[3]))
#convert(::Type{Tuple{}}, x::Tuple) = _tuple_error(Tuple{}, x)
#convert(::Type{Tuple{S}}, x::Tuple) = _tuple_error(Tuple{S}, x)
#convert(::Type{Tuple{S, T}}, x::Tuple{Any, Any}) where {S, T} =_tuple_error(Tuple{S, T}, x)
#convert(::Type{Tuple{S, T, U}}, x::Tuple{Any, Any, Any}) where {S, T, U} = _tuple_error(Tuple{S, T, U}, x)

"""
    oftype(x, y)

Convert `y` to the type of `x` i.e. `convert(typeof(x), y)`.

# Examples
```jldoctest
julia> x = 4;

julia> y = 3.;

julia> oftype(x, y)
3

julia> oftype(y, x)
4.0
```
"""
oftype(x, y) = y isa typeof(x) ? y : convert(typeof(x), y)::typeof(x)

unsigned(x::Int) = reinterpret(UInt, x)
signed(x::UInt) = reinterpret(Int, x)

"""
    cconvert(T,x)

Convert `x` to a value to be passed to C code as type `T`, typically by calling `convert(T, x)`.

In cases where `x` cannot be safely converted to `T`, unlike [`convert`](@ref), `cconvert` may
return an object of a type different from `T`, which however is suitable for
[`unsafe_convert`](@ref) to handle. The result of this function should be kept valid (for the GC)
until the result of [`unsafe_convert`](@ref) is not needed anymore.
This can be used to allocate memory that will be accessed by the `ccall`.
If multiple objects need to be allocated, a tuple of the objects can be used as return value.

Neither `convert` nor `cconvert` should take a Julia object and turn it into a `Ptr`.
"""
function cconvert end

cconvert(::Type{T}, x) where {T} = x isa T ? x : convert(T, x) # do the conversion eagerly in most cases
cconvert(::Type{Union{}}, x...) = convert(Union{}, x...)
cconvert(::Type{<:Ptr}, x) = x # but defer the conversion to Ptr to unsafe_convert
unsafe_convert(::Type{T}, x::T) where {T} = x # unsafe_convert (like convert) defaults to assuming the convert occurred
unsafe_convert(::Type{T}, x::T) where {T<:Ptr} = x  # to resolve ambiguity with the next method
unsafe_convert(::Type{P}, x::Ptr) where {P<:Ptr} = convert(P, x)
unsafe_convert(::Type{Ptr{UInt8}}, s::String) = ccall(:jl_string_ptr, Ptr{UInt8}, (Any,), s)
unsafe_convert(::Type{Ptr{Int8}}, s::String) = ccall(:jl_string_ptr, Ptr{Int8}, (Any,), s)

"""
    reinterpret(::Type{Out}, x::In)

Change the type-interpretation of the binary data in the isbits value `x`
to that of the isbits type `Out`.
The size (ignoring padding) of `Out` has to be the same as that of the type of `x`.
For example, `reinterpret(Float32, UInt32(7))` interprets the 4 bytes corresponding to `UInt32(7)` as a
[`Float32`](@ref). Note that `reinterpret(In, reinterpret(Out, x)) === x`

```jldoctest
julia> reinterpret(Float32, UInt32(7))
1.0f-44

julia> reinterpret(NTuple{2, UInt8}, 0x1234)
(0x34, 0x12)

julia> reinterpret(UInt16, (0x34, 0x12))
0x1234

julia> reinterpret(Tuple{UInt16, UInt8}, (0x01, 0x0203))
(0x0301, 0x02)
```

!!! note

    The treatment of padding differs from reinterpret(::DataType, ::AbstractArray).

!!! warning

    Use caution if some combinations of bits in `Out` are not considered valid and would
    otherwise be prevented by the type's constructors and methods. Unexpected behavior
    may result without additional validation.

"""
function reinterpret(::Type{Out}, x) where {Out}
    @inline
    if isprimitivetype(Out) && isprimitivetype(typeof(x))
        return bitcast(Out, x)
    end
    # only available when Base is fully loaded.
    return _reinterpret(Out, x)
end

"""
    sizeof(T::DataType)
    sizeof(obj)

Size, in bytes, of the canonical binary representation of the given `DataType` `T`, if any.
Or the size, in bytes, of object `obj` if it is not a `DataType`.

See also [`Base.summarysize`](@ref).

# Examples
```jldoctest
julia> sizeof(Float32)
4

julia> sizeof(ComplexF64)
16

julia> sizeof(1.0)
8

julia> sizeof(collect(1.0:10.0))
80

julia> struct StructWithPadding
           x::Int64
           flag::Bool
       end

julia> sizeof(StructWithPadding) # not the sum of `sizeof` of fields due to padding
16

julia> sizeof(Int64) + sizeof(Bool) # different from above
9
```

If `DataType` `T` does not have a specific size, an error is thrown.

```jldoctest
julia> sizeof(AbstractArray)
ERROR: Abstract type AbstractArray does not have a definite size.
Stacktrace:
[...]
```
"""
sizeof(x) = Core.sizeof(x)

"""
    ifelse(condition::Bool, x, y)

Return `x` if `condition` is `true`, otherwise return `y`. This differs from `?` or `if` in
that it is an ordinary function, so all the arguments are evaluated first. In some cases,
using `ifelse` instead of an `if` statement can eliminate the branch in generated code and
provide higher performance in tight loops.

# Examples
```jldoctest
julia> ifelse(1 > 2, 1, 2)
2
```
"""
ifelse(condition::Bool, x, y) = Core.ifelse(condition, x, y)

"""
    esc(e)

Only valid in the context of an [`Expr`](@ref) returned from a macro. Prevents the macro hygiene
pass from turning embedded variables into gensym variables. See the [Macros](@ref man-macros)
section of the Metaprogramming chapter of the manual for more details and examples.
"""
esc(@nospecialize(e)) = Expr(:escape, e)

"""
    @boundscheck(blk)

Annotates the expression `blk` as a bounds checking block, allowing it to be elided by [`@inbounds`](@ref).

!!! note
    The function in which `@boundscheck` is written must be inlined into
    its caller in order for `@inbounds` to have effect.

# Examples
```jldoctest; filter = r"Stacktrace:(\\n \\[[0-9]+\\].*)*"
julia> @inline function g(A, i)
           @boundscheck checkbounds(A, i)
           return "accessing (\$A)[\$i]"
       end;

julia> f1() = return g(1:2, -1);

julia> f2() = @inbounds return g(1:2, -1);

julia> f1()
ERROR: BoundsError: attempt to access 2-element UnitRange{Int64} at index [-1]
Stacktrace:
 [1] throw_boundserror(::UnitRange{Int64}, ::Tuple{Int64}) at ./abstractarray.jl:455
 [2] checkbounds at ./abstractarray.jl:420 [inlined]
 [3] g at ./none:2 [inlined]
 [4] f1() at ./none:1
 [5] top-level scope

julia> f2()
"accessing (1:2)[-1]"
```

!!! warning

    The `@boundscheck` annotation allows you, as a library writer, to opt-in to
    allowing *other code* to remove your bounds checks with [`@inbounds`](@ref).
    As noted there, the caller must verify—using information they can access—that
    their accesses are valid before using `@inbounds`. For indexing into your
    [`AbstractArray`](@ref) subclasses, for example, this involves checking the
    indices against its [`axes`](@ref). Therefore, `@boundscheck` annotations
    should only be added to a [`getindex`](@ref) or [`setindex!`](@ref)
    implementation after you are certain its behavior is correct.
"""
macro boundscheck(blk)
    return Expr(:if, Expr(:boundscheck), esc(blk))
end

"""
    @inbounds(blk)

Eliminates array bounds checking within expressions.

In the example below the in-range check for referencing
element `i` of array `A` is skipped to improve performance.

```julia
function sum(A::AbstractArray)
    r = zero(eltype(A))
    for i in eachindex(A)
        @inbounds r += A[i]
    end
    return r
end
```

!!! warning

    Using `@inbounds` may return incorrect results/crashes/corruption
    for out-of-bounds indices. The user is responsible for checking it manually.
    Only use `@inbounds` when you are certain that all accesses are in bounds (as
    undefined behavior, e.g. crashes, might occur if this assertion is violated). For
    example, using `1:length(A)` instead of `eachindex(A)` in a function like
    the one above is _not_ safely inbounds because the first index of `A` may not
    be `1` for all user defined types that subtype `AbstractArray`.
"""
macro inbounds(blk)
    return Expr(:block,
        Expr(:inbounds, true),
        Expr(:local, Expr(:(=), :val, esc(blk))),
        Expr(:inbounds, :pop),
        :val)
end

"""
    @label name

Labels a statement with the symbolic label `name`. The label marks the end-point
of an unconditional jump with [`@goto name`](@ref).
"""
macro label(name::Symbol)
    return esc(Expr(:symboliclabel, name))
end

"""
    @goto name

`@goto name` unconditionally jumps to the statement at the location [`@label name`](@ref).

`@label` and `@goto` cannot create jumps to different top-level statements. Attempts cause an
error. To still use `@goto`, enclose the `@label` and `@goto` in a block.
"""
macro goto(name::Symbol)
    return esc(Expr(:symbolicgoto, name))
end

# linear indexing
function getindex(A::Array, i::Int)
    @_noub_if_noinbounds_meta
    @boundscheck checkbounds(A, i)
    memoryrefget(memoryrefnew(getfield(A, :ref), i, false), :not_atomic, false)
end
# simple Array{Any} operations needed for bootstrap
function setindex!(A::Array{Any}, @nospecialize(x), i::Int)
    @_noub_if_noinbounds_meta
    @boundscheck checkbounds(A, i)
    memoryrefset!(memoryrefnew(getfield(A, :ref), i, false), x, :not_atomic, false)
    return A
end
setindex!(A::Memory{Any}, @nospecialize(x), i::Int) = (memoryrefset!(memoryrefnew(A, i, @_boundscheck), x, :not_atomic, @_boundscheck); A)
setindex!(A::MemoryRef{T}, x) where {T} = (memoryrefset!(A, convert(T, x), :not_atomic, @_boundscheck); A)
setindex!(A::MemoryRef{Any}, @nospecialize(x)) = (memoryrefset!(A, x, :not_atomic, @_boundscheck); A)

# SimpleVector

getindex(v::SimpleVector, i::Int) = (@_foldable_meta; Core._svec_ref(v, i))
function length(v::SimpleVector)
    @_total_meta
    t = @_gc_preserve_begin v
    len = unsafe_load(Ptr{Int}(pointer_from_objref(v)))
    @_gc_preserve_end t
    return len
end
firstindex(v::SimpleVector) = 1
lastindex(v::SimpleVector) = length(v)
iterate(v::SimpleVector, i=1) = (length(v) < i ? nothing : (v[i], i + 1))
eltype(::Type{SimpleVector}) = Any
keys(v::SimpleVector) = OneTo(length(v))
isempty(v::SimpleVector) = (length(v) == 0)
axes(v::SimpleVector) = (OneTo(length(v)),)
axes(v::SimpleVector, d::Integer) = d <= 1 ? axes(v)[d] : OneTo(1)

function ==(v1::SimpleVector, v2::SimpleVector)
    length(v1)==length(v2) || return false
    for i = 1:length(v1)
        v1[i] == v2[i] || return false
    end
    return true
end

map(f, v::SimpleVector) = Any[ f(v[i]) for i = 1:length(v) ]

getindex(v::SimpleVector, I::AbstractArray) = Core.svec(Any[ v[i] for i in I ]...)

unsafe_convert(::Type{Ptr{Any}}, sv::SimpleVector) = convert(Ptr{Any},pointer_from_objref(sv)) + sizeof(Ptr)

"""
    isassigned(array, i)::Bool

Test whether the given array has a value associated with index `i`. Return `false`
if the index is out of bounds, or has an undefined reference.

# Examples
```jldoctest
julia> isassigned(rand(3, 3), 5)
true

julia> isassigned(rand(3, 3), 3 * 3 + 1)
false

julia> mutable struct Foo end

julia> v = similar(rand(3), Foo)
3-element Vector{Foo}:
 #undef
 #undef
 #undef

julia> isassigned(v, 1)
false
```
"""
function isassigned end

function isassigned(v::SimpleVector, i::Int)
    @boundscheck 1 <= i <= length(v) || return false
    return true
end


"""
    Colon()

Colons (:) are used to signify indexing entire objects or dimensions at once.

Very few operations are defined on Colons directly; instead they are converted
by [`to_indices`](@ref) to an internal vector type (`Base.Slice`) to represent the
collection of indices they span before being used.

The singleton instance of `Colon` is also a function used to construct ranges;
see [`:`](@ref).
"""
struct Colon <: Function
end
const (:) = Colon()


"""
    Val(c)

Return `Val{c}()`, which contains no run-time data. Types like this can be used to
pass the information between functions through the value `c`, which must be an `isbits`
value or a `Symbol`. The intent of this construct is to be able to dispatch on constants
directly (at compile time) without having to test the value of the constant at run time.

# Examples
```jldoctest
julia> f(::Val{true}) = "Good"
f (generic function with 1 method)

julia> f(::Val{false}) = "Bad"
f (generic function with 2 methods)

julia> f(Val(true))
"Good"
```
"""
struct Val{x}
end

Val(x) = Val{x}()

"""
    inferencebarrier(x)

A shorthand for `compilerbarrier(:type, x)` causes the type of this statement to be inferred as `Any`.
See [`Base.compilerbarrier`](@ref) for more info.
"""
inferencebarrier(@nospecialize(x)) = compilerbarrier(:type, x)

"""
    isempty(collection)::Bool

Determine whether a collection is empty (has no elements).

!!! warning

    `isempty(itr)` may consume the next element of a stateful iterator `itr`
    unless an appropriate [`Base.isdone(itr)`](@ref) method is defined.
    Stateful iterators *should* implement `isdone`, but you may want to avoid
    using `isempty` when writing generic code which should support any iterator
    type.

# Examples
```jldoctest
julia> isempty([])
true

julia> isempty([1 2 3])
false
```
"""
function isempty(itr)
    d = isdone(itr)
    d !== missing && return d
    iterate(itr) === nothing
end

"""
    values(iterator)

For an iterator or collection that has keys and values, return an iterator
over the values.
This function simply returns its argument by default, since the elements
of a general iterator are normally considered its "values".

# Examples
```jldoctest; filter = r"^\\s+\\d\$"m
julia> d = Dict("a"=>1, "b"=>2);

julia> values(d)
ValueIterator for a Dict{String, Int64} with 2 entries. Values:
  2
  1

julia> values([2])
1-element Vector{Int64}:
 2
```
"""
values(itr) = itr

"""
    Missing

A type with no fields whose singleton instance [`missing`](@ref) is used
to represent missing values.

See also: [`skipmissing`](@ref), [`nonmissingtype`](@ref), [`Nothing`](@ref).
"""
struct Missing end

"""
    missing

The singleton instance of type [`Missing`](@ref) representing a missing value.

See also: [`NaN`](@ref), [`skipmissing`](@ref), [`nonmissingtype`](@ref).
"""
const missing = Missing()

"""
    ismissing(x)

Indicate whether `x` is [`missing`](@ref).

See also: [`skipmissing`](@ref), [`isnothing`](@ref), [`isnan`](@ref).
"""
ismissing(x) = x === missing

function popfirst! end

"""
    peek(stream[, T=UInt8])

Read and return a value of type `T` from a stream without advancing the current position
in the stream.   See also [`startswith(stream, char_or_string)`](@ref).

# Examples

```jldoctest
julia> b = IOBuffer("julia");

julia> peek(b)
0x6a

julia> position(b)
0

julia> peek(b, Char)
'j': ASCII/Unicode U+006A (category Ll: Letter, lowercase)
```

!!! compat "Julia 1.5"
    The method which accepts a type requires Julia 1.5 or later.
"""
function peek end

"""
    @__LINE__ -> Int

Expand to the line number of the location of the macrocall.
Return `0` if the line number could not be determined.
"""
macro __LINE__()
    return __source__.line
end

# Iteration
"""
    isdone(itr, [state])::Union{Bool, Missing}

This function provides a fast-path hint for iterator completion.
This is useful for stateful iterators that want to avoid having elements
consumed if they are not going to be exposed to the user (e.g. when checking
for done-ness in `isempty` or `zip`).

Stateful iterators that want to opt into this feature should define an `isdone`
method that returns true/false depending on whether the iterator is done or
not. Stateless iterators need not implement this function.

If the result is `missing`, then `isdone` cannot determine whether the iterator
state is terminal, and callers must compute `iterate(itr, state) === nothing`
to obtain a definitive answer.

See also [`iterate`](@ref), [`isempty`](@ref)
"""
isdone(itr, state...) = missing

"""
    iterate(iter [, state])::Union{Nothing, Tuple{Any, Any}}

Advance the iterator to obtain the next element. If no elements
remain, `nothing` should be returned. Otherwise, a 2-tuple of the
next element and the new iteration state should be returned.
"""
function iterate end

"""
    isiterable(T)::Bool

Test if type `T` is an iterable collection type or not,
that is whether it has an `iterate` method or not.
"""
function isiterable(T)::Bool
    return hasmethod(iterate, Tuple{T})
end

"""
    @world(sym, world)

Resolve the binding `sym` in world `world`. See [`invoke_in_world`](@ref) for running
arbitrary code in fixed worlds. `world` may be `UnitRange`, in which case the macro
will error unless the binding is valid and has the same value across the entire world
range.

As a special case, the world `∞` always refers to the latest world, even if that world
is newer than the world currently running.

The `@world` macro is primarily used in the printing of bindings that are no longer
available in the current world.

## Example
```julia-repl
julia> struct Foo; a::Int; end
Foo

julia> fold = Foo(1)

julia> Int(Base.get_world_counter())
26866

julia> struct Foo; a::Int; b::Int end
Foo

julia> fold
@world(Foo, 26866)(1)
```

!!! compat "Julia 1.12"
    This functionality requires at least Julia 1.12.
"""
macro world(sym, world)
    if world == :∞
        world = Expr(:call, get_world_counter)
    end
    if isa(sym, Symbol)
        return :($(_resolve_in_world)($(esc(world)), $(QuoteNode(GlobalRef(__module__, sym)))))
    elseif isa(sym, GlobalRef)
        return :($(_resolve_in_world)($(esc(world)), $(QuoteNode(sym))))
    elseif isa(sym, Expr) && sym.head === :(.) &&
            length(sym.args) == 2 && isa(sym.args[2], QuoteNode) && isa(sym.args[2].value, Symbol)
        return :($(_resolve_in_world)($(esc(world)), $(GlobalRef)($(esc(sym.args[1])), $(sym.args[2]))))
    else
        error("`@world` requires a symbol or GlobalRef")
    end
end

_resolve_in_world(world::Integer, gr::GlobalRef) =
    invoke_in_world(UInt(world), Core.getglobal, gr.mod, gr.name)

# Special constprop heuristics for various binary opes
typename(typeof(function + end)).constprop_heuristic  = Core.SAMETYPE_HEURISTIC
typename(typeof(function - end)).constprop_heuristic  = Core.SAMETYPE_HEURISTIC
typename(typeof(function * end)).constprop_heuristic  = Core.SAMETYPE_HEURISTIC
typename(typeof(function == end)).constprop_heuristic = Core.SAMETYPE_HEURISTIC
typename(typeof(function != end)).constprop_heuristic = Core.SAMETYPE_HEURISTIC
typename(typeof(function <= end)).constprop_heuristic = Core.SAMETYPE_HEURISTIC
typename(typeof(function >= end)).constprop_heuristic = Core.SAMETYPE_HEURISTIC
typename(typeof(function < end)).constprop_heuristic  = Core.SAMETYPE_HEURISTIC
typename(typeof(function > end)).constprop_heuristic  = Core.SAMETYPE_HEURISTIC
