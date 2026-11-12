select n, public.check_rate_limit('test:loop', 3, 60) as allowed
from generate_series(1, 4) as n;