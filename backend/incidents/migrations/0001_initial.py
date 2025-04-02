# Generated by Django 5.0.3 on 2025-03-23 17:43

from django.db import migrations, models


class Migration(migrations.Migration):

    initial = True

    dependencies = [
    ]

    operations = [
        migrations.CreateModel(
            name='Incident',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('title', models.CharField(max_length=255)),
                ('description', models.TextField()),
                ('incident_type', models.CharField(choices=[('fire', 'Fire'), ('accident', 'Accident'), ('medical', 'Medical Emergency'), ('crime', 'Crime'), ('other', 'Other')], max_length=20)),
                ('photo', models.ImageField(blank=True, null=True, upload_to='incidents/photos/')),
                ('voice_note', models.FileField(blank=True, null=True, upload_to='incidents/voice_notes/')),
                ('latitude', models.DecimalField(decimal_places=6, max_digits=9)),
                ('longitude', models.DecimalField(decimal_places=6, max_digits=9)),
                ('status', models.CharField(choices=[('pending', 'Pending'), ('in_progress', 'In Progress'), ('resolved', 'Resolved'), ('closed', 'Closed')], default='pending', max_length=20)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'db_table': 'incidents',
                'ordering': ['-created_at'],
            },
        ),
    ]
