rem Assigning a bool (comparison result) to a numeric variable is a type
rem mismatch: bool is distinct and does not widen to numeric. MUST be rejected.
x = 2 > 1
