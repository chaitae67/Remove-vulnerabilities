<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>회원가입</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div><#include "/fragments/header.ftl"></div>
<main class="narrow">
    <section class="panel">
        <p class="eyebrow">Join</p>
        <h1>회원가입</h1>
        <#if error??><div class="flash error">${error}</div></#if>
        <form action="/register" method="post" class="stack-form">
            <input type="hidden" name="${_csrf.parameterName}" value="${_csrf.token}">
            <input name="username" placeholder="아이디" required>
            <input name="password" type="password" placeholder="비밀번호 (영문·숫자·특수문자 포함 10자 이상)" required
                   minlength="10" pattern="(?=.*[A-Za-z])(?=.*\d)(?=.*[^A-Za-z0-9]).{10,}"
                   title="영문, 숫자, 특수문자를 모두 포함하여 10자 이상 입력하세요.">
            <input name="name" placeholder="성함" required>
            <input name="email" type="email" placeholder="이메일" required>
            <input name="phone" placeholder="휴대전화번호">
            <button class="button" type="submit">가입하기</button>
        </form>
    </section>
</main>
<div><#include "/fragments/footer.ftl"></div>
</body>
</html>
