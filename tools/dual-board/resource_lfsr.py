"""Exact GF(2) arithmetic and independently checkable maximal-period proofs."""
def factors(n):
    answer=[];divisor=2
    while divisor*divisor<=n:
        if n%divisor==0:
            answer.append(divisor)
            while n%divisor==0:n//=divisor
        divisor+=1
    if n>1:answer.append(n)
    return answer

def multiply(a,b,bits,polynomial):
    result=0;mask=(1<<bits)-1
    while b:
        if b&1:result^=a
        b>>=1;carry=a>>(bits-1);a=(a<<1)&mask
        if carry:a^=polynomial
    return result

def power_x(exponent,bits,polynomial):
    value=1;base=2
    while exponent:
        if exponent&1:value=multiply(value,base,bits,polynomial)
        base=multiply(base,base,bits,polynomial);exponent>>=1
    return value

def primitive(bits):
    period=(1<<bits)-1;primes=factors(period)
    for polynomial in range(3,1<<bits,2):
        if power_x(period,bits,polynomial)!=1:continue
        residues={str(p):power_x(period//p,bits,polynomial) for p in primes}
        if all(value!=1 for value in residues.values()):
            return dict(bits=bits,polynomial=polynomial,period=period,
                        prime_divisors=primes,period_power=1,proper_divisor_powers=residues)
    raise RuntimeError('No primitive polynomial found')
