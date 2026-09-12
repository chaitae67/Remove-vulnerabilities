<#assign navActive = "qna">
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Q&A 관리 - Zero Day Clinic 관리자</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
<#include "/admin/_header.ftl">
<main class="admin-page">
    <section class="page-title">
        <p class="eyebrow">Q&amp;A</p>
        <h1>Q&amp;A 관리</h1>
        <p>문의 글을 클릭하면 상세에서 답변을 등록하거나 삭제할 수 있습니다.</p>
    </section>

    <section class="content-band">
        <div class="section-head">
            <h2>전체 문의</h2>
            <span class="muted">${posts?size}건</span>
        </div>
        <#if posts?has_content>
        <div class="admin-table-wrap">
            <table class="admin-table">
                <thead>
                <tr>
                    <th scope="col">제목</th>
                    <th scope="col">작성자</th>
                    <th scope="col">공개</th>
                    <th scope="col">상태</th>
                    <th scope="col">작성일</th>
                    <th scope="col"><span class="sr-only">상세</span></th>
                </tr>
                </thead>
                <tbody>
                <#list posts as post>
                <tr data-href="/admin/qna/${post.id}">
                    <td><a class="cell-link" href="/admin/qna/${post.id}">${post.title?html}</a></td>
                    <td>${post.writer.name?html}</td>
                    <td><#if post.privatePost><span class="state status-canceled">비공개</span><#else><span class="state">공개</span></#if></td>
                    <td><#if post.answered><span class="state status-paid">답변완료</span><#else><span class="state status-ready">대기</span></#if></td>
                    <td><time>${temporals.format(post.createdAt, 'yyyy.MM.dd')}</time></td>
                    <td class="cell-action"><a href="/admin/qna/${post.id}">상세 &rsaquo;</a></td>
                </tr>
                </#list>
                </tbody>
            </table>
        </div>
        <#else>
        <div class="empty-state">
            <strong>등록된 문의가 없습니다.</strong>
            <p>고객이 Q&amp;A를 남기면 이곳에 표시됩니다.</p>
        </div>
        </#if>
    </section>
</main>
<script src="/js/admin-rowlink.js"></script>
<script src="/js/admin-showmore.js"></script>
</body>
</html>
