<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>오류가 발생했습니다</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#-- WEB-22: 사용자 정의 에러 페이지. 프레임워크/서버 정보, 스택트레이스, 예외 메시지, 요청 경로 등은 노출하지 않는다. -->
<main class="content-band" style="max-width:640px;margin:80px auto;text-align:center;">
    <section class="panel">
        <p class="eyebrow">Error</p>
        <h1>요청을 처리할 수 없습니다</h1>
        <p>처리 중 문제가 발생했습니다.<#if status??> (오류 코드: ${status})</#if></p>
        <p class="muted">잠시 후 다시 시도해 주세요.</p>
        <p><a class="button" href="/admin">관리자 홈으로</a></p>
    </section>
</main>
</body>
</html>
