# Copyright 2015 Andreas Noack
module TSVD

    export tsvd

    using Base.BLAS
    using Base.LinAlg: givensAlgorithm

    import Base: hcat
    import Base.LinAlg: A_mul_B!, Ac_mul_B!, BlasComplex, BlasFloat, BlasReal
    import Base.LinAlg: axpy!

    function hcat{T<:AbstractVecOrMat}(x::Vector{T})
        l    = length(x)
        if l == 0
            throw(ArgumentError("cannot flatten empty vector"))
        else
            x1   = x[1]
            m, n = size(x1, 1), size(x1, 2)
            B    = similar(x1, eltype(x1), (m, l*n))
            for i = 1:l
                B[:, (i - 1)*n + 1:i*n] = x[i]
            end
            return B
        end
    end

    # Necessary to handle quaternions
    function axpy!(α, x::AbstractArray, y::AbstractArray)
        n = length(x)
        if n != length(y)
            throw(DimensionMismatch("x has length $n, but y has length $(length(y))"))
        end
        for i = 1:n
            @inbounds y[i] += x[i]*α
        end
        y
    end

    A_mul_B!{T<:BlasFloat}(α::Number, A::StridedMatrix{T}, x::StridedVector{T}, β::Number, y::StridedVector{T}) = gemv!('N', convert(T, α), A, x, convert(T, β), y)
    Ac_mul_B!{T<:BlasReal}(α::Number, A::StridedMatrix{T}, x::StridedVector{T}, β::Number, y::StridedVector{T}) = gemv!('T', convert(T, α), A, x, convert(T, β), y)
    Ac_mul_B!{T<:BlasComplex}(α::Number, A::StridedMatrix{T}, x::StridedVector{T}, β::Number, y::StridedVector{T}) = gemv!('C', convert(T, α), A, x, convert(T, β), y)

    function A_mul_B!(α::Number, A::StridedMatrix, x::StridedVector, β::Number, y::StridedVector)
        n = length(y)
        for i = 1:n
            y[i] *= β
        end
        for i = 1:n
            for l = 1:size(A,2)
                y[i] += α*A[i,l]*x[l]
            end
        end
        return y
    end

    function Ac_mul_B!(α::Number, A::StridedMatrix, x::StridedVector, β::Number, y::StridedVector)
        n = length(y)
        for i = 1:n
            y[i] *= β
        end
        for i = 1:n
            for l = 1:size(A,2)
                y[i] += α*A[l,i]'*x[l]
            end
        end
        return y
    end

    function bidiag(A, steps, τ, αs, βs, U, V, μs, νs, reorth_in, tolError)

        m, n = size(A)
        reorth_b = reorth_in
        nReorth = 0
        nReorthVecs = 0

        normA = norm(A, Inf)

        T = eltype(A)
        Tr = real(T)

        maxνs = Tr[]
        maxμs = Tr[]

        iter = length(αs)

        u = U[iter + 1]
        # if iter == 0
        #     v = similar(u, size(A, 2))
        #     v = fill!(v,0)
        #     β = zero(eltype(βs))
        # else
        #     v = copy(V[iter])
        #     β = βs[iter]
        # end
        v = V[iter]
        β = βs[iter]

        for j = iter + (1:steps)

            # The v step
            vOld = v
            ## apply operator
            v = A'u
            axpy!(T(-β), vOld, v)
            α = norm(v)

            ## run ω recurrence
            reorth_ν = Int[]
            for i = 1:j - 1
                # τ = eps(T)*(hypot(α, β) + hypot(αs[i], βs[i - 1])) + eps(T)*normA ### this doesn't seem to be better than fixed τ = eps
                ν = βs[i]*μs[i + 1] + αs[i]*μs[i] - β*νs[i]
                ν = (ν + copysign(τ, ν))/α
                if abs(ν) > tolError
                    push!(reorth_ν, i)
                end
                νs[i] = ν
            end
            if j > 1
                push!(maxνs, maximum(abs(νs)))
            end
            push!(νs, 1)

            ## reorthogonalize if necessary
            if reorth_b || length(reorth_ν) > 0
                # for i = reorth_ν
                #     axpy!(-Base.dot(V[i], v), V[i], v)
                #     νs[i] = 2eps(Tr)
                #     nReorthVecs += 1
                # end
                for i = 1:j - 1
                    axpy!(-Base.dot(V[i], v), V[i], v)
                    νs[i] = eps(Tr)
                    nReorthVecs += 1
                end
                α = norm(v)
                reorth_b = !reorth_b
            end

            ## update the result vectors
            push!(αs, α)
            scale!(v, inv(α))
            push!(V, v)

            # The u step
            uOld = u
            ## apply operator
            u = A*v
            axpy!(T(-α), uOld, u)
            β = norm(u)

            ## run ω recurrence
            reorth_μ = Int[]
            for i = 1:j
                # τ = eps(T)*(hypot(α, β) + hypot(αs[i], (i == j ? β : βs[i]))) + eps(T)*normA ### this doesn't seem to be better than fixed τ = eps
                μ = αs[i]*νs[i] - α*μs[i]
                if i > 1
                    μ += βs[i - 1]*νs[i-1]
                end
                μ = (μ + copysign(τ, μ))/β
                if abs(μ) > tolError
                    push!(reorth_μ, i)
                end
                μs[i] = μ
            end
            push!(maxμs, maximum(μs))
            push!(μs, 1)

            ## reorthogonalize if necessary
            if reorth_b || length(reorth_μ) > 0
                # for i in reorth_μ
                #     axpy!(-Base.dot(U[i], u), U[i], u)
                #     μs[i] = 2eps(Tr)
                #     nReorthVecs += 1
                # end
                for i in 1:j
                    axpy!(-Base.dot(U[i], u), U[i], u)
                    μs[i] = eps(Tr)
                    nReorthVecs += 1
                end
                β = norm(u)
                reorth_b = !reorth_b
                nReorth += 1
            end

            ## update the result vectors
            push!(βs, β)
            scale!(u, inv(β))
            push!(U, u)
        end

        αs, βs, U, V, μs, νs, reorth_b, maxμs, maxνs, nReorth, nReorthVecs
    end

    """
## tsvd(A, [nVals = 1, maxIter = 1000, initVec = randn(m), tolConv = 1e-12, tolError = 0.0])

Computes the truncated singular value decomposition (TSVD) by Lanczos bidiagonalization of the operator `A`. The Lanczos vectors are partially orthogonalized as described in

R. M. Larsen, *Lanczos bidiagonalization with partial reorthogonalization*, Department of Computer Science, Aarhus University, Technical report, DAIMI PB-357, September 1998.

Note! At the moment the default is complete orthogonalization because the ω recurrences that measure the orthogonality of the Lanczos vectors still requires some fine tuning.

**Arguments:**

- `A`: Anything that supports the in place update operations

```julia
A_mul_B!(α::Number, A, x::Vector, β::Number, y::Vector)
``` and
```julia
Ac_mul_B!(α::Number, A, x::Vector, β::Number, y::Vector)
```
corresponding to the operations `y := α*op(A)*x + β*y` where `op` can be either
the identity or the conjugate transpose of `A`.

- `nVals`: The number of singular values and vectors to compute. Default is one (the largest).

- `maxIter`: The maximum number of iterations of the Lanczos bidiagonalization. Default is 1000, but usually much fewer iterations are needed.

- `initVec`: Initial `U` vector for the Lanczos procesdure. Default is a real vector of real Gaussian random variates. Should have the same element type as the operator `A`.

- `tolConv`: Relative convergence criterion for the singular values. Default is `1e-12`.

- `tolError`: Absolute tolerance for the inner product of the Lanczos vectors as measured by the ω recurrence. Default is `0.0` which corresponds to complete reorthogonalization. `Inf` corresponds to no reorthogonalization.

**Output:**

The output of the procesure it the truple tuple `(U,s,V)`

- `U`: `size(A,1)` times `nVals` matrix of left singular vectors.
- `s`: Vector of length `nVals` of the singular values of `A`.
- `V`: `size(A,2)` times `nVals` matrix of right singular vectors.
    """
    function tsvd(A,
        nVals = 1,
        maxIter = 1000,
        initVec = convert(Vector{eltype(A)}, randn(size(A,1)));
        tolConv = 1e-12,
        tolError = eps(real(eltype(A)))) # The ω recurrence is still not fine tunes so we do full reorthogonalization

        Tv = eltype(initVec)
        Tr = real(Tv)

        # error estimate used in ω recurrence
        # τ = eps(Tr)*countnz(A)/mean(size(A))*norm(A, Inf)
        τ = eps(Tr)*norm(A, Inf)

        # I need to append βs with a zero at each iteration. Tt is much easier for type inference if it is a vector with the right element type
        z = zeros(Tr, 1)

        # Iteration count and step size
        cc = max(5, nVals)
        steps = 5

        # initialize the αs, βs, U and V. Use result of first matvec to infer the correct types.
        # So the first iteration is run here, but slightly differently from the rest of the iterations
        nrmInit = norm(initVec)
        v = A'initVec
        scale!(v, inv(nrmInit))
        α = norm(v)
        scale!(v, inv(α))
        V = fill(v, 1)
        αs = fill(α, 1)
        ν = 1 + τ/abs(α)

        u = A*v
        uOld = similar(u)
        copy!(uOld, initVec)
        scale!(uOld, inv(nrmInit))
        axpy!(eltype(u)(-α), uOld, u)
        β = norm(u)
        scale!(u, inv(β))
        U = typeof(u)[uOld, u]
        βs = fill(β, 1)
        μ = τ/β

        # Arrays for saving the estimates of the maximum angles between Lanczos vectors
        maxμs = Tr[]
        maxνs = Tr[]

        # return types can only be inferred by man, not the machine
        αs::Vector{Tr},
        βs::Vector{Tr},
        U::Vector{typeof(v)}, # for some reason typeof(U) doesn't work here
        V::Vector{typeof(v)},
        μs::Vector{Tr},
        νs::Vector{Tr},
        reorth_b::Bool, maxμ, maxν, _ = bidiag(A, cc, τ, αs, βs, U, V, [μ, 1], [one(μ)], false, tolError)

        # Save the estimates of the maximum angles between Lanczos vectors
        append!(maxμs, maxμ)

        vals0 = svdvals(Bidiagonal([αs; z], βs, false))
        vals1 = vals0

        hasConv = false
        while cc <= maxIter
            _, _, _, _, _, _, reorth_b, maxμ, maxν, _ = bidiag(A, steps, τ, αs, βs, U, V, μs, νs, reorth_b, tolError)
            append!(maxμs, maxμ)
            append!(maxνs, maxν)

            vals1 = Base.LinAlg.svdvals(Bidiagonal([αs; z], βs, false))
            if vals0[nVals]*(1 - tolConv) < vals1[nVals] < vals0[nVals]*(1 + tolConv)
                hasConv = true
                break
            end
            vals0 = vals1
            cc += steps
        end
        if !hasConv
            error("no convergence")
        end

        # Form upper bidiagonal square matrix
        # m = length(U[1])
        # for j = 1:length(αs)
        #     # Calculate Givens rotation
        #     c, s, αs[j] = givensAlgorithm(αs[j], βs[j])

        #     # Update left vector
        #     # for i = 1:m
        #     #     uij       = U[j][i]
        #     #     uij1      = U[j+1][i]
        #     #     U[j][i]   = uij*c + uij1*s'
        #     #     U[j+1][i] = uij1*c - uij*s
        #     # end

        #     # Update bidiagonal matrix
        #     if j < length(αs)
        #         αj1 = αs[j + 1]
        #         αs[j + 1] = c*αj1
        #         βs[j] = s*αj1
        #     end
        # end

        # Calculate the bidiagonal SVD and update U and V
        mU = hcat(U[1:end-1])
        mV = hcat(V)
        B = Bidiagonal(αs, βs[1:end-1], true)
        smU, sms, smV = svd(B)

        return (mU*smU)[:,1:nVals],
            sms[1:nVals],
            (mV*smV)[:,1:nVals],
            Bidiagonal(αs, βs[1:end-1], true),
            mU,
            mV,
            maxμs,
            maxνs
    end
end