<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zero Day Clinic 관리자 로그인</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<main class="content-band" style="max-width:520px;margin:80px auto;">
    <section class="panel">
        <p class="eyebrow">ADMIN</p>
        <h1>관리자 로그인</h1>
        <#-- 스프링 시큐리티는 /login?error, /login?logout 으로 리다이렉트하므로
             모델 속성이 아니라 요청 파라미터(param)를 봐야 한다. -->
        <#if param.error??>
            <div class="flash error">아이디 또는 비밀번호를 확인해 주세요.</div>
        </#if>
        <#if param.logout??>
            <div class="flash success">로그아웃되었습니다.</div>
        </#if>
        <form action="/login" method="post" class="stack-form">
            <label>아이디<input type="text" name="username" autocomplete="username" required></label>
            <label>비밀번호<input type="password" name="password" autocomplete="current-password" required></label>
            <button class="button" type="submit">관리자 로그인</button>
        </form>
    </section>
</main>
</body>
</html>
