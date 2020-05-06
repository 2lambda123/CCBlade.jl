#=
Author: Andrew Ning

A general blade element momentum (BEM) method for propellers/fans and turbines.

Some unique features:
- a simple yet very robust solution method ideal for use with optimization
- designed for compatibility with algorithmic differentiation tools
- allows for arbitrary inflow conditions, including reversed flow, hover, etc.
- convenience methods for common wind turbine inflow scenarios

=#

module CCBlade


import FLOWMath

export Rotor, Section, OperatingPoint, Outputs
export af_from_files, af_from_data
export simple_op, windturbine_op
export solve, thrusttorque, nondim


include("airfoils.jl")  # all the code related to airfoil data

# --------- Correction Methods -----------

# -- Mach ---

abstract type MachCorrection end

struct NoMachCorrection <: MachCorrection end
struct PrandtlGlauert <: MachCorrection end
struct KarmanTsien <: MachCorrection end

function machcorrection(::NoMachCorrection, cl, cd, Mach)
    return cl, cd
end

function machcorrection(::PrantlGlauert, cl, cd, Mach)
    beta = sqrt(1 - Mach^2)
    cl /= beta
    return cl, cd
end

function machcorrection(::KarmanTsien, cl, cd, Mach)
    beta = sqrt(1 - Mach^2)
    cl = 1.0/(beta/cl + Mach^2/(2*(1 + beta)))
    return cl, cd
end

# -- Reynolds number ---

abstract type ReCorrection end

struct NoReCorrection <: ReCorrection end
struct SkinFriction <: ReCorrection 
    Re0::TF  # reference reynolds number
    p::TF  # exponent.  ~0.2 fully turbulent (Schlichting), 0.5 fully laminar (Blasius)
end

function recorrection(::NoReCorrection, cl, cd, Re)
    return cl, cd
end

function recorrection(sf::SkinFriction, cl, cd, Re)
    cd *= (sf.Re0 / Re)^sf.p
    return cl, cd
end


# -- Rotation ---

abstract type RotationCorrection end

struct NoRotationCorrection <: RotationCorrection
struct DuSeligEggers <: RotationCorrection
    a::TF
    b::TF
    d::TF
end
DuSeligEggers() = DuSeligEggers(1.0, 1.0, 1.0)

function rotationcorrection(::NoRotationCorrection, cl, cd, cr, rR, tsr, alpha, phi)
    return cl, cd
end

function rotationcorrection(du::DuSeligEggers, cl, cd, cr, rR, tsr, alpha, phi)
    # Du-Selig correction for lift
    Lambda = tsr / sqrt(1 + tsr^2)
    expon = du.d / (Lambda * rR)
    fcl = 1.0/(2*pi)*(1.6*cr/0.1267*(du.a-cr^expon)/(du.b+cr^expon)-1)
    cl_linear = 2*pi*(alpha - alpha0)
    deltacl = fcl*(cl_linear - cl)
    cl += deltacl

    # Eggers correction for drag
    deltacd = deltacl*(sin(phi) - 0.12*cos(phi))/(cos(phi) + 0.12*sin(phi))  # note that we can actually use phi instead of alpha as is done in airfoilprep.py b/c this is done at each iteration
    cd += deltacd

    return cl, cd
end    


# --- tip correction  ---

abstract type TipCorrection end 

struct NoTipCorrection <: TipCorrection end
struct PrandtlTipOnly <: TipCorrection end
struct Prandtl <: TipCorrection end

function tiplossfactor(::NoTipCorrection, r, Rhub, Rtip, phi, B)
    return 1.0
end

function tiplossfactor(::PrandtlTipOnly, r, Rhub, Rtip, phi, B)
    
    asphi = abs(sin(phi))
    factortip = B/2.0*(Rtip/r - 1)/asphi
    F = 2.0/pi*acos(exp(-factortip))

    return F
end

function tiplossfactor(::Prandtl, r, Rhub, Rtip, phi, B)

    # Prandtl's tip and hub loss factor
    asphi = abs(sin(phi))
    factortip = B/2.0*(Rtip/r - 1)/asphi
    Ftip = 2.0/pi*acos(exp(-factortip))
    factorhub = B/2.0*(r/Rhub - 1)/asphi
    Fhub = 2.0/pi*acos(exp(-factorhub))
    F = Ftip * Fhub

    return F
end

# --------- structs -------------

"""
    Rotor(Rhub, Rtip, B; precone=0.0, flipcamber=false, negateoutputs=false)

Scalar parameters defining the rotor.  

**Arguments**
- `Rhub::Float64`: hub radius (along blade length)
- `Rtip::Float64`: tip radius (along blade length)
- `B::Int64`: number of blades
- `flipcamber::Bool`: true if flip airfoil camber as would typically be desired for turbine operation.
- `negateoutputs::Bool`: true if you want to negate the outputs as would be convention for turbines
- `precone::Float64`: precone angle
"""
struct Rotor{TF, TI, TB}

    Rhub::TF
    Rtip::TF
    B::TI
    precone::TF
    flipcamber::TB
    negateoutputs::TB
    MachC::MachCorrection
    ReC::ReCorrection
    rotationC::RotationCorrection
    tipC::TipCorrection
end

# convenience constructor with keyword parameters
Rotor(Rhub, Rtip, B; precone=0.0, flipcamber=false, negateoutputs=false, MachC=NoMachCorrection(), 
    ReC=NoReCorrection(), rotationC=NoRotationCorrection(), tipC=Prandtl()) = Rotor(Rhub, Rtip, 
    B, precone, flipcamber, negateoutputs, machC, ReC, rotationC, tipC)


"""
    Section(r, chord, theta, af)

Define sectional properties for one station along rotor
    
**Arguments**
- `r::Float64`: radial location along blade (`Rhub < r < Rtip`)
- `chord::Float64`: corresponding local chord length
- `theta::Float64`: corresponding twist angle (radians)
- `af::function`: a function of the form: `cl, cd = af(alpha, Re, Mach)`
"""
struct Section{TF1, TF2, TF3, TAF}
    
    r::TF1  # different types b.c. of dual numbers.  often r is fixed, while chord/theta vary.
    chord::TF2
    theta::TF3
    af::TAF

end


# convenience function to access fields within an array of structs
function Base.getproperty(obj::Vector{Section{TF1, TF2, TF3, TAF}}, sym::Symbol) where {TF1, TF2, TF3, TAF}
    return getfield.(obj, sym)
end


"""
    OperatingPoint(Vx, Vy, rho, pitch=0.0, mu=1.0, asound=1.0)

Operation point for a rotor.  
The x direction is the axial direction, and y direction is the tangential direction in the rotor plane.  
See Documentation for more detail on coordinate systems.
Vx and Vy vary radially at same locations as `r` in the rotor definition.

**Arguments**
- `Vx::Float64`: velocity in x-direction along blade
- `Vy::Float64`: velocity in y-direction along blade
- `pitch::Float64`: pitch angle (radians)
- `rho::Float64`: fluid density
- `mu::Float64`: fluid dynamic viscosity (unused if Re not included in airfoil data)
- `asound::Float64`: fluid speed of sound (unused if Mach not included in airfoil data)
"""
struct OperatingPoint{TF, TF2}
    Vx::TF
    Vy::TF
    rho::TF2  # different type to accomodate ReverseDiff
    pitch::TF2  
    mu::TF2
    asound::TF2
end

# convenience constructor when Re and Mach are not used.
OperatingPoint(Vx, Vy, rho) = OperatingPoint(Vx, Vy, rho, zero(rho), one(rho), one(rho)) 

# convenience function to access fields within an array of structs
function Base.getproperty(obj::Vector{OperatingPoint{TF, TF2}}, sym::Symbol) where {TF, TF2}
    return getfield.(obj, sym)
end


"""
    Outputs(Np, Tp, a, ap, u, v, phi, alpha, W, cl, cd, cn, ct, F, G)

Outputs from the BEM solver along the radius.

**Arguments**
- `Np::Vector{Float64}`: normal force per unit length
- `Tp::Vector{Float64}`: tangential force per unit length
- `a::Vector{Float64}`: axial induction factor
- `ap::Vector{Float64}`: tangential induction factor
- `u::Vector{Float64}`: axial induced velocity
- `v::Vector{Float64}`: tangential induced velocity
- `phi::Vector{Float64}`: inflow angle
- `alpha::Vector{Float64}`: angle of attack
- `W::Vector{Float64}`: inflow velocity
- `cl::Vector{Float64}`: lift coefficient
- `cd::Vector{Float64}`: drag coefficient
- `cn::Vector{Float64}`: normal force coefficient
- `ct::Vector{Float64}`: tangential force coefficient
- `F::Vector{Float64}`: hub/tip loss correction
- `G::Vector{Float64}`: effective hub/tip loss correction for induced velocities: `u = Vx * a * G, v = Vy * ap * G`
"""
struct Outputs{TF}

    Np::TF
    Tp::TF
    a::TF
    ap::TF
    u::TF
    v::TF
    phi::TF
    alpha::TF
    W::TF
    cl::TF
    cd::TF
    cn::TF
    ct::TF
    F::TF
    G::TF

end

# convenience constructor to initialize
Outputs() = Outputs(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

# convenience function to access fields within an array of structs
function Base.getproperty(obj::Vector{Outputs{TF}}, sym::Symbol) where TF
    return getfield.(obj, sym)
end


# -------------------------------




# ------------ BEM core ------------------

"""
(private) residual function
"""
function residual(phi, rotor, section, op)

    # unpack inputs
    r = section.r
    chord = section.chord
    theta = section.theta
    af = section.af

    Rhub = rotor.Rhub
    Rtip = rotor.Rtip
    B = rotor.B
    
    Vx = op.Vx
    Vy = op.Vy
    rho = op.rho
    pitch = op.pitch
    
    # constants
    sigma_p = B*chord/(2.0*pi*r)
    sphi = sin(phi)
    cphi = cos(phi)

    # angle of attack
    alpha = (theta + pitch) - phi

    # Reynolds/Mach number
    W0 = sqrt(Vx^2 + Vy^2)  # ignoring induction, which is generally a very minor difference and only affects Reynolds/Mach number
    Re = rho * W0 * chord / op.mu
    Mach = W0/op.asound  # also ignoring induction

    # airfoil cl/cd
    if rotor.flipcamber
        cl, cd = af(-alpha, Re, Mach)
        cl *= -1
    else
        cl, cd = af(alpha, Re, Mach)
    end

    # airfoil corrections
    cl, cd = machcorrection(rotor.MachC, cl, cd, Mach)
    cl, cd = recorrection(rotor.ReC, cl, cd, Re)
    cl, cd = rotationcorrection(rotor.rotationC, cl, cd, chord/r, r/Rtip, Vy/Vx*Rtip/r, alpha, phi)

    # resolve into normal and tangential forces
    cn = cl*cphi - cd*sphi
    ct = cl*sphi + cd*cphi

    # hub/tip loss
    F = tiplossfactor(rotor.tipC, r, Rhub, Rtip, phi, B)   

    # sec parameters
    k = cn*sigma_p/(4.0*F*sphi*sphi)
    kp = ct*sigma_p/(4.0*F*sphi*cphi)

    # --- solve for induced velocities ------
    if isapprox(Vx, 0.0, atol=1e-6)

        u = sign(phi)*kp*cn/ct*Vy
        v = zero(phi)
        a = zero(phi)
        ap = zero(phi)
        R = sign(phi) - k

    elseif isapprox(Vy, 0.0, atol=1e-6)
        
        u = zero(phi)
        v = k*ct/cn*abs(Vx)
        a = zero(phi)
        ap = zero(phi)
        R = sign(Vx) + kp
    
    else

        if phi < 0
            k *= -1
        end

        if isapprox(k, 1.0, atol=1e-6)  # state corresopnds to Vx=0, return any nonzero residual
            return 1.0, Outputs()
        end

        if k >= -2.0/3  # momentum region
            a = k/(1 - k)

        else  # empirical region
            g1 = F*(2*k - 1) + 10.0/9
            g2 = F*(F - 2*k - 4.0/3)
            g3 = 2*F*(1 - k) - 25.0/9

            if isapprox(g3, 0.0, atol=1e-6)  # avoid singularity
                a = 1.0/(2.0*sqrt(g2)) - 1
            else
                a = (g1 + sqrt(g2)) / g3
            end
        end

        u = a * Vx

        # -------- tangential induction ----------
        if Vx < 0
            kp *= -1
        end

        if isapprox(kp, -1.0, atol=1e-6)  # state corresopnds to Vy=0, return any nonzero residual
            return 1.0, Outputs()
        end

        ap = kp/(1 + kp)
        v = ap * Vy


        # ------- residual function -------------
        R = sin(phi)/(1 + a) - Vx/Vy*cos(phi)/(1 - ap)
    end


    # ------- loads ---------
    W = sqrt((Vx + u)^2 + (Vy - v)^2)
    Np = cn*0.5*rho*W^2*chord
    Tp = ct*0.5*rho*W^2*chord

    # The BEM methodology applies hub/tip losses to the loads rather than to the velocities.  
    # This is the most common way to implement a BEM, but it means that the raw velocities are misleading 
    # as they do not contain any hub/tip loss corrections.
    # To fix this we compute the effective hub/tip losses that would produce the same thrust/torque.
    # In other words:
    # CT = 4 a (1 + a) F = 4 a G (1 + a G)\n
    # This is solved for G, then multiplied against the wake velocities.
    
    if isapprox(Vx, 0.0, atol=1e-6)
        G = sqrt(F)
    elseif isapprox(Vy, 0.0, atol=1e-6)
        G = F
    else
        G = (-1.0 + sqrt(1.0 + 4*a*(1.0 + a)*F))/(2*a)
    end
    u *= G
    v *= G

    if rotor.negateoutputs
        return R, Outputs(-Np, -Tp, -a, -ap, -u, -v, phi, -alpha, W, -cl, cd, -cn, -ct, F, G)
    else
        return R, Outputs(Np, Tp, a, ap, u, v, phi, alpha, W, cl, cd, cn, ct, F, G)
    end

end




"""
(private) Find a bracket for the root closest to xmin by subdividing
interval (xmin, xmax) into n intervals.

Returns found, xl, xu.
If found = true a bracket was found between (xl, xu)
"""
function firstbracket(f, xmin, xmax, n, backwardsearch=false)

    xvec = range(xmin, xmax, length=n)
    if backwardsearch  # start from xmax and work backwards
        xvec = reverse(xvec)
    end

    fprev = f(xvec[1])
    for i = 2:n
        fnext = f(xvec[i])
        if fprev*fnext < 0  # bracket found
            if backwardsearch
                return true, xvec[i], xvec[i-1]
            else
                return true, xvec[i-1], xvec[i]
            end
        end
        fprev = fnext
    end

    return false, 0.0, 0.0
end


"""
    solve(rotor, section, op)

Solve the BEM equations for given rotor geometry and operating point.

**Arguments**
- `rotor::Rotor`: rotor properties
- `section::Section`: section properties
- `op::OperatingPoint`: operating point

**Returns**
- `outputs::Outputs`: BEM output data including loads, induction factors, etc.
"""
function solve(rotor, section, op)

    # error handling
    if typeof(section) <: Vector
        error("You passed in an vector for section, but this funciton does not accept an vector.\nProbably you intended to use broadcasting (notice the dot): solve.(Ref(rotor), sections, ops)")
    end

    # check if we are at hub/tip
    if isapprox(section.r, rotor.Rhub, atol=1e-6) || isapprox(section.r, rotor.Rtip, atol=1e-6)
        return Outputs()  # no loads at hub/tip
    end

    # parameters
    npts = 20  # number of discretization points to find bracket in residual solve

    # unpack
    Vx = op.Vx
    Vy = op.Vy
    theta = section.theta + op.pitch

    # ---- determine quadrants based on case -----
    Vx_is_zero = isapprox(Vx, 0.0, atol=1e-6)
    Vy_is_zero = isapprox(Vy, 0.0, atol=1e-6)

    # quadrants
    epsilon = 1e-6
    q1 = [epsilon, pi/2]
    q2 = [-pi/2, -epsilon]
    q3 = [pi/2, pi-epsilon]
    q4 = [-pi+epsilon, -pi/2]

    if Vx_is_zero && Vy_is_zero
        return Outputs()

    elseif Vx_is_zero

        startfrom90 = false  # start bracket at 0 deg.

        if Vy > 0 && theta > 0
            order = (q1, q2)
        elseif Vy > 0 && theta < 0
            order = (q2, q1)
        elseif Vy < 0 && theta > 0
            order = (q3, q4)
        else  # Vy < 0 && theta < 0
            order = (q4, q3)
        end

    elseif Vy_is_zero

        startfrom90 = true  # start bracket search from 90 deg

        if Vx > 0 && abs(theta) < pi/2
            order = (q1, q3)
        elseif Vx < 0 && abs(theta) < pi/2
            order = (q2, q4)
        elseif Vx > 0 && abs(theta) > pi/2
            order = (q3, q1)
        else  # Vx < 0 && abs(theta) > pi/2
            order = (q4, q2)
        end

    else  # normal case

        startfrom90 = false

        if Vx > 0 && Vy > 0
            order = (q1, q2, q3, q4)
        elseif Vx < 0 && Vy > 0
            order = (q2, q1, q4, q3)
        elseif Vx > 0 && Vy < 0
            order = (q3, q4, q1, q2)
        else  # Vx[i] < 0 && Vy[i] < 0
            order = (q4, q3, q2, q1)
        end

    end

        

    # ----- solve residual function ------

    # # wrapper to residual function to accomodate format required by fzero
    R(phi) = residual(phi, rotor, section, op)[1]

    success = false
    for j = 1:length(order)  # quadrant orders.  In most cases it should find root in first quadrant searched.
        phimin, phimax = order[j]

        # check to see if it would be faster to reverse the bracket search direction
        backwardsearch = false
        if !startfrom90
            if phimin == -pi/2 || phimax == -pi/2  # q2 or q4
                backwardsearch = true
            end
        else
            if phimax == pi/2  # q1
                backwardsearch = true
            end
        end
        
        # force to dual numbers if necessary
        phimin = phimin*one(section.chord)
        phimax = phimax*one(section.chord)

        # find bracket
        success, phiL, phiU = firstbracket(R, phimin, phimax, npts, backwardsearch)

        # once bracket is found, solve root finding problem and compute loads
        if success
            phistar, _ = FLOWMath.brent(R, phiL, phiU)
            _, outputs = residual(phistar, rotor, section, op)
            return outputs
        end    
    end    

    # it shouldn't get to this point.  if it does it means no solution was found
    # it will return empty outputs
    # alternatively, one could increase npts and try again
    
    @warn "Invalid data (likely) for this section.  Zero loading assumed."
    return Outputs()
end



# ------------ inflow ------------------



"""
    simple_op(Vinf, Omega, r, rho; pitch=0.0, mu=1.0, asound=1.0, precone=0.0)

Uniform inflow through rotor.  Returns an Inflow object.

**Arguments**
- `Vinf::Float`: freestream speed (m/s)
- `Omega::Float`: rotation speed (rad/s)
- `r::Float`: radial location where inflow is computed (m)
- `pitch::Float`: pitch angle (rad)
- `rho::Float`: air density (kg/m^3)
- `mu::Float`: air viscosity (Pa * s)
- `asounnd::Float`: air speed of sound (m/s)
- `precone::Float`: precone angle (rad)
"""
function simple_op(Vinf, Omega, r, rho; pitch=zero(rho), mu=one(rho), asound=one(rho), precone=zero(Vinf))

    # error handling
    if typeof(r) <: Vector
        error("You passed in an vector for r, but this function does not accept an vector.\nProbably you intended to use broadcasting")
    end

    Vx = Vinf * cos(precone) 
    Vy = Omega * r * cos(precone)

    return OperatingPoint(Vx, Vy, rho, pitch, mu, asound)

end


"""
    windturbine_op(Vhub, Omega, pitch, r, precone, yaw, tilt, azimuth, hubHt, shearExp, rho, mu=1.0, asound=1.0)

Compute relative wind velocity components along blade accounting for inflow conditions
and orientation of turbine.  See Documentation for angle definitions.

**Arguments**
- `Vhub::Float64`: freestream speed at hub (m/s)
- `Omega::Float64`: rotation speed (rad/s)
- `pitch::Float64`: pitch angle (rad)
- `r::Float64`: radial location where inflow is computed (m)
- `precone::Float64`: precone angle (rad)
- `yaw::Float64`: yaw angle (rad)
- `tilt::Float64`: tilt angle (rad)
- `azimuth::Float64`: azimuth angle to evaluate at (rad)
- `hubHt::Float64`: hub height (m) - used for shear
- `shearExp::Float64`: power law shear exponent
- `rho::Float64`: air density (kg/m^3)
- `mu::Float64`: air viscosity (Pa * s)
- `asound::Float64`: air speed of sound (m/s)
"""
function windturbine_op(Vhub, Omega, pitch, r, precone, yaw, tilt, azimuth, hubHt, shearExp, rho, mu=1.0, asound=1.0)

    sy = sin(yaw)
    cy = cos(yaw)
    st = sin(tilt)
    ct = cos(tilt)
    sa = sin(azimuth)
    ca = cos(azimuth)
    sc = sin(precone)
    cc = cos(precone)

    # coordinate in azimuthal coordinate system
    x_az = -r*sin(precone)
    z_az = r*cos(precone)
    y_az = 0.0  # could omit (the more general case allows for presweep so this is nonzero)

    # get section heights in wind-aligned coordinate system
    heightFromHub = (y_az*sa + z_az*ca)*ct - x_az*st

    # velocity with shear
    V = Vhub*(1 + heightFromHub/hubHt)^shearExp

    # transform wind to blade c.s.
    Vwind_x = V * ((cy*st*ca + sy*sa)*sc + cy*ct*cc)
    Vwind_y = V * (cy*st*sa - sy*ca)

    # wind from rotation to blade c.s.
    Vrot_x = -Omega*y_az*sc
    Vrot_y = Omega*z_az

    # total velocity
    Vx = Vwind_x + Vrot_x
    Vy = Vwind_y + Vrot_y

    # operating point
    return OperatingPoint(Vx, Vy, rho, pitch, mu, asound)

end

# -------------------------------------


# -------- convenience methods ------------

"""
    thrusttorque(rotor, sections, outputs::Vector{Outputs{TF}}) where TF

integrate the thrust/torque across the blade, 
including 0 loads at hub/tip, using a trapezoidal rule.

**Arguments**
- `rotor::Rotor`: rotor object
- `sections::Vector{Section}`: rotor object
- `outputs::Vector{Outputs}`: output data along blade

**Returns**
- `T::Float64`: thrust (along x-dir see Documentation).
- `Q::Float64`: torque (along x-dir see Documentation).
"""
# function thrusttorque(rotor, sections, outputs)
function thrusttorque(rotor, sections, outputs::Vector{Outputs{TF}}) where TF

    # add hub/tip for complete integration.  loads go to zero at hub/tip.
    rfull = [rotor.Rhub; sections.r; rotor.Rtip]
    Npfull = [0.0; outputs.Np; 0.0]
    Tpfull = [0.0; outputs.Tp; 0.0]

    # integrate Thrust and Torque (trapezoidal)
    thrust = Npfull*cos(rotor.precone)
    torque = Tpfull.*rfull*cos(rotor.precone)

    T = rotor.B * FLOWMath.trapz(rfull, thrust)
    Q = rotor.B * FLOWMath.trapz(rfull, torque)

    return T, Q
end


"""
    thrusttorque(rotor, sections, outputs::Array{Outputs{TF}, 2}) where TF

Integrate the thrust/torque across the blade given an array of output data.
Generally used for azimuthal averaging of thrust/torque.
`outputs[i, j]` corresponds to `sections[i], azimuth[j]`.  Integrates across azimuth
"""
function thrusttorque(rotor, sections, outputs::Matrix{Outputs{TF}}) where TF

    T = 0.0
    Q = 0.0
    nr, naz = size(outputs)

    for j = 1:naz
        Tsub, Qsub = thrusttorque(rotor, sections, outputs[:, j])
        T += Tsub / naz
        Q += Qsub / naz
    end

    return T, Q
end




"""
    nondim(T, Q, Vhub, Omega, rho, rotor)

Nondimensionalize the outputs.

**Arguments**
- `T::Float64`: thrust (N)
- `Q::Float64`: torque (N-m)
- `Vhub::Float64`: hub speed used in turbine normalization (m/s)
- `Omega::Float64`: rotation speed used in propeller normalization (rad/s)
- `rho::Float64`: air density (kg/m^3)
- `rotor::Rotor`: rotor object
- `type::String`: normalization type

**Returns**

if type == "windturbine"
- `CP::Float64`: power coefficient
- `CT::Float64`: thrust coefficient
- `CQ::Float64`: torque coefficient

if type == "propeller"
- `eff::Float64`: efficiency
- `CT::Float64`: thrust coefficient
- `CQ::Float64`: torque coefficient

if type == "helicopter"
- `FM::Float64`: figure of merit
- `CT::Float64`: thrust coefficient
- `CQ or CP::Float64`: torque/power coefficient (they are identical)
"""
function nondim(T, Q, Vhub, Omega, rho, rotor, type)

    P = Q * Omega
    Rp = rotor.Rtip*cos(rotor.precone)

    if type == "windturbine"  # wind turbine normalizations

        q = 0.5 * rho * Vhub^2
        A = pi * Rp^2

        CP = P / (q * A * Vhub)
        CT = T / (q * A)
        CQ = Q / (q * Rp * A)

        return CP, CT, CQ

    elseif type == "propeller"

        n = Omega/(2*pi)
        Dp = 2*Rp

        if T < 0
            eff = 0.0  # creating drag not thrust
        else
            eff = T*Vhub/P
        end
        CT = T / (rho * n^2 * Dp^4)
        CQ = Q / (rho * n^2 * Dp^5)

        return eff, CT, CQ

    elseif type == "helicopter"

        A = pi * Rp^2

        CT = T / (rho * A * (Omega*Rp)^2)
        CP = P / (rho * A * (Omega*Rp)^3)  # note that CQ = CP
        FM = CT^(3.0/2)/(sqrt(2)*CP)

        return FM, CT, CP
    end

end


end  # module
