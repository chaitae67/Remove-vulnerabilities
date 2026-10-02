<#assign navActive = "notices">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>공지사항 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title with-action">
        <div><p class="eyebrow">NOTICES</p><h1>공지사항 관리</h1><p>고객 페이지에 노출할 공지를 관리합니다.</p></div>
        <a class="button" href="/admin/notices/new">공지 작성</a>
    </section>
    <section class="content-band">
        <#if notices?has_content>
        <div class="admin-table-wrap"><table class="admin-table">
            <thead><tr><th>제목</th><th>작성자</th><th>작성일</th><th><span class="sr-only">상세</span></th></tr></thead>
            <tbody><#list notices as notice>
            <tr data-href="/admin/notices/${notice.id?c}">
                <td><a class="cell-link" href="/admin/notices/${notice.id?c}">${notice.title?html}</a></td>
                <td>${notice.author.name?html}</td>
                <td>${temporals.format(notice.createdAt, 'yyyy.MM.dd HH:mm')}</td>
                <td class="cell-action"><a href="/admin/notices/${notice.id?c}">상세 &rsaquo;</a></td>
            </tr>
            </#list></tbody>
        </table></div>
        <#else><div class="empty-state"><strong>등록된 공지사항이 없습니다.</strong></div></#if>
    </section>
</main>
<script src="/js/admin-rowlink.js"></script>
</body>
</html>
