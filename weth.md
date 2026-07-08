I got back to my hobby of decompiling EVM contracts. Here are some fun things in the decompiled WETH contract.



- The Solidity `ether.transfer()` relays 2300 gas to the called address.

- But the low-level call unintuitively relays "0" gas when it sends some value.

- That's one of those weird EVM quirks at the client level.

- The clients always add 2300 gas to calls with value.

- The compiler knows this and resolves the 2300 gas correctly for both cases.



So if you have a call with `{gas: 2, value: 1}`, it will relay 2302 gas.



That got me thinking this could be an issue if you're setting gas caps manually while allowing the value to be either zero or non-zero.





- The old compiler version used by WETH doesn't perform calldata size checks.

- You can cripple the last argument to be less than 32 bytes, and the remaining bytes will be padded with 0s.

- You can cripple the whole argument, and it will be 0.

- You can cripple all the arguments, and they will be 0.

- Modern compilers would add a check to revert in that case.



What's funny is that:



`address(weth).call(hex"23b872dd")`



will be a valid:



`transferFrom(address(0), address(0), 0)`



There could be some edge cases in contracts integrating WETH that allow this behavior.
