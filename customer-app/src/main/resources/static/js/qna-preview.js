document.addEventListener('DOMContentLoaded', () => {
    const form = document.querySelector('form[action="/qna"]');
    const button = document.getElementById('qna-preview-button');
    if (!form || !button) return;
    const files = document.getElementById('qna-files');
    const section = document.getElementById('qna-preview-section');
    const images = document.getElementById('qna-preview-images');
    const names = document.getElementById('qna-preview-files');
    let objectUrls = [];
    button.addEventListener('click', () => {
        if (!form.reportValidity()) return;
        document.getElementById('qna-preview-title').textContent = form.elements.title.value;
        document.getElementById('qna-preview-content').textContent = form.elements.content.value;
        objectUrls.forEach(URL.revokeObjectURL);
        objectUrls = [];
        images.replaceChildren();
        names.replaceChildren();
        Array.from(files.files).forEach(file => {
            if (/^image\/(png|jpeg|webp|gif)$/.test(file.type)) {
                const url = URL.createObjectURL(file);
                objectUrls.push(url);
                const image = document.createElement('img');
                image.src = url;
                image.alt = file.name;
                images.appendChild(image);
            }
            const name = document.createElement('span');
            name.textContent = file.name;
            names.appendChild(name);
        });
        section.hidden = false;
        section.scrollIntoView({behavior: 'smooth', block: 'start'});
    });
});
