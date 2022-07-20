# Memotics Contract Audit

2022 July 6

Prepared by: [vectorized.eth](https://twitter.com/optimizoor)  

# Scope

The contents of `Homie.sol` were audited at the following commit hash:

[https://github.com/Vectorized/Solidity-Code-Reviews/commit/684180b94c57bf49d9f10d5c539609772b608506](https://github.com/Vectorized/Solidity-Code-Reviews/commit/684180b94c57bf49d9f10d5c539609772b608506)

# Limitations

No assessment can guarantee the absolute safety or security of a software-based system. Further, a system can become unsafe or insecure over time as it and/or its environment evolves. This assessment aimed to discover as many issues and make as many suggestions for improvement as possible within the specified time frame. Undiscovered issues, even serious ones, may remain. Issues may also exist in components and dependencies not included in the assessment scope.

# Findings

Findings and recommendations are listed in this section, grouped into broad categories. It is up to the team behind the code to ultimately decide whether the items listed here qualify as issues that need to be fixed, and whether any suggested changes are worth adopting. When a response from the team regarding a finding is available, it is provided.

Findings are given a severity rating based on their likelihood of causing harm in practice and the potential magnitude of their negative impact. Severity is only a rough guideline as to the risk an issue presents, and all issues should be carefully evaluated.

**Severity Level Determination**

|  | High Impact | Medium Impact | Low Impact |
| --- | --- | --- | --- |
| High Likelihood | Critical | High | Medium |
| Medium Likelihood | High | Medium | Low |
| Low Likelihood | Medium | Low | Low |

Issues that do not present any quantifiable risk (as is common for issues in the Code Quality category) are given a severity of **Informational.**

## Security and Correctness

The contract logic is correct with no reentrancy risks. No high impact or high likelihood issues are identified and presented.

## Gas Optimizations

Contract is optimized well with tight variable packing where needed. Representation is reflective of recommended standards for best practice and optimal minting cost implementations.

## Conclusion

Overall the contracts written do not present any major deviance to the standards and best practice with ERC721 tokens. Code written is appropriate to the development of gas optimized minting.
