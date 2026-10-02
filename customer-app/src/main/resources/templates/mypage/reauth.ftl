<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>본인 확인</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow"><section class="panel">
    <p class="eyebrow">Re-authentication</p>
    <h1>본인 확인</h1>
    <p class="muted">개인정보 수정 전 현재 비밀번호를 다시 확인합니다.</p>
    <#if reauthError??><div class="flash error">${reauthError}</div></#if>
    <form class="stack-form" action="/mypage/reauth" method="post">
        <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
        <label for="password">현재 비밀번호</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <button class="button" type="submit">확인</button>
    </form>
</section></main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
