/// bilibili 接口响应信封（{code, message, data}）的判定逻辑。
///
/// 抽成纯函数便于单元测试：这个判定写错会导致「未登录时整个 App 报错」这类问题。
library;

/// 判断某个业务 code 是否应被视为成功。
///
/// - `code == 0` 永远成功
/// - [acceptCodes] 中显式列出的 code 也视为成功
///
/// 为什么需要 [acceptCodes]：
/// `/x/web-interface/nav` 在未登录时返回 `code = -101`（账号未登录），
/// 但它的 `data` 里仍然带着 WBI 签名所需的 `wbi_img`。
/// 如果不放行 -101，就拿不到签名密钥，进而导致首页、热门、我的全部报错。
bool isEnvelopeOk(int? code, Set<int> acceptCodes) {
  if (code == null) return true;
  if (code == 0) return true;
  return acceptCodes.contains(code);
}
