<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>비밀번호 재설정</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">Reset Password</p>
        <h1>비밀번호 재설정</h1>
        <#if error??><div class="flash error">${error}</div></#if>
        <form action="/reset-password" method="post" class="stack-form">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input type="hidden" name="token" value="${token}">
            <input name="newPassword" type="password" placeholder="새 비밀번호" required minlength="6">
            <button class="button" type="submit">비밀번호 변경</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
